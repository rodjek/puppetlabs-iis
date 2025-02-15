require 'rexml/document'
require 'securerandom'
require 'open3'
require 'base64'
require File.join(File.dirname(__FILE__), 'compatible_powershell_version')

# @api private
module PuppetX
  # @api private
  module IIS
    # PowerShell manager
    class PowerShellManager
      @@instances = {}

      def self.instance(cmd, debug = false, pipe_timeout = 180)
        key = cmd + debug.to_s
        manager = @@instances[key]

        if manager.nil? || !manager.alive?
          # ignore any errors trying to tear down this unusable instance
          begin
            manager.exit if manager
          rescue
            nil
          end
          @@instances[key] = PowerShellManager.new(cmd, debug, pipe_timeout)
        end

        @@instances[key]
      end

      def self.win32console_enabled?
        @win32console_enabled ||= defined?(Win32) &&
                                  defined?(Win32::Console) &&
                                  Win32::Console.class == Class
      end

      def self.compatible_version_of_powershell?
        @compatible_powershell_version ||= PuppetX::PuppetLabs::IIS::CompatiblePowerShellVersion.compatible_version?
      end

      def self.supported?
        Puppet::Util::Platform.windows? &&
          compatible_version_of_powershell? &&
          !win32console_enabled?
      end

      def initialize(cmd, debug, pipe_timeout)
        @usable = true

        named_pipe_name = "#{SecureRandom.uuid}PuppetPsHost"

        ps_args = ['-File', self.class.init_path, "\"#{named_pipe_name}\""]
        ps_args << '"-EmitDebugOutput"' if debug
        # @stderr should never be written to as PowerShell host redirects output
        stdin, @stdout, @stderr, @ps_process = Open3.popen3("#{cmd} #{ps_args.join(' ')}")
        stdin.close

        Puppet.debug "#{Time.now} #{cmd} is running as pid: #{@ps_process[:pid]}"

        pipe_path = "\\\\.\\pipe\\#{named_pipe_name}"
        # wait for the pipe server to signal ready, and fail if no response in 10 seconds

        # wait up to 180 seconds in 0.2 second intervals to be able to open the pipe
        # If the pipe_timeout is ever specified as less than the sleep interval it will
        # never try to connect to a pipe and error out as if a timeout occurred.
        sleep_interval = 0.2
        (pipe_timeout / sleep_interval).to_int.times do
          begin
            # pipe is opened in binary mode and must always
            @pipe = File.open(pipe_path, 'r+b')
            break
          rescue
            sleep sleep_interval
          end
        end
        if @pipe.nil?
          # Tear down and kill the process if unable to connect to the pipe; failure to do so
          # results in zombie processes being left after the puppet run. We discovered that
          # Closing @ps_process via .kill instead of using this method actually kills the watcher
          # and leaves an orphaned process behind. Failing to close stdout and stderr also leaves
          # clutter behind, so explicitly close those too.
          @stdout.close unless @stdout.closed?
          @stderr.close unless @stderr.closed?
          Process.kill('KILL', @ps_process[:pid]) if @ps_process.alive?
          raise "Failure waiting for PowerShell process #{@ps_process[:pid]} to start pipe server"
        end
        Puppet.debug "#{Time.now} PowerShell initialization complete for pid: #{@ps_process[:pid]}"

        at_exit { exit }
      end

      def alive?
        # powershell process running
        @ps_process.alive? &&
          # explicitly set during a read / write failure, like broken pipe EPIPE
          @usable &&
          # an explicit failure state might not have been hit, but IO may be closed
          self.class.stream_valid?(@pipe) &&
          self.class.stream_valid?(@stdout) &&
          self.class.stream_valid?(@stderr)
      end

      def execute(powershell_code, timeout_ms = nil, working_dir = nil, environment_variables = [])
        code = make_ps_code(powershell_code, timeout_ms, working_dir, environment_variables)

        # err is drained stderr pipe (not captured by redirection inside PS)
        # or during a failure, a Ruby callstack array
        out, native_stdout, err = exec_read_result(code)

        # an error was caught during execution that has invalidated any results
        return { exitcode: -1, stderr: err } if !@usable && out.nil?

        out[:exitcode] = out[:exitcode].to_i unless out[:exitcode].nil?
        # if err contains data it must be "real" stderr output
        # which should be appended to what PS has already captured
        out[:stderr] = out[:stderr].nil? ? [] : [out[:stderr]]
        out[:stderr] += err unless err.nil?
        out[:native_stdout] = native_stdout

        out
      end

      def exit
        @usable = false

        Puppet.debug 'PowerShellManager exiting...'

        # ask PowerShell pipe server to shutdown if its still running
        # rather than expecting the pipe.close to terminate it
        begin
          write_pipe(pipe_command(:exit)) unless @pipe.closed?
        rescue
          nil
        end

        # pipe may still be open, but if stdout / stderr are dead PS process is in trouble
        # and will block forever on a write to the pipe
        # its safer to close pipe on Ruby side, which gracefully shuts down PS side
        @pipe.close unless @pipe.closed?
        @stdout.close unless @stdout.closed?
        @stderr.close unless @stderr.closed?

        # wait up to 2 seconds for the watcher thread to fully exit
        @ps_process.join(2)
      end

      def self.init_path
        # a PowerShell -File compatible path to bootstrap the instance
        path = File.expand_path('../../../templates/iis', __FILE__)
        path = File.join(path, 'init_ps.ps1').tr('/', '\\')

        Puppet.debug "\"#{path}\""

        "\"#{path}\""
      end

      def make_ps_code(powershell_code, timeout_ms = nil, working_dir = nil, environment_variables = [])
        begin
          timeout_ms = Integer(timeout_ms)
          # Lower bound protection. The polling resolution is only 50ms
          if timeout_ms < 50 then timeout_ms = 50 end
        rescue
          timeout_ms = 300 * 1000
        end

        # Environment array firstly needs to be parsed and converted into a hashtable.  And then
        # the values passed in need to be converted to a PowerShell Hashtable.
        #
        # Environment parsing is based on the Puppet exec equivalent code
        # https://github.com/puppetlabs/puppet/blob/a9f77d71e992fc2580de7705847e31264e0fbebe/lib/puppet/provider/exec.rb#L35-L49
        environment = {}
        if envlist = environment_variables
          envlist = [envlist] unless envlist.is_a? Array
          envlist.each do |setting|
            if setting =~ %r{^(\w+)=((.|\n)+)$}
              env_name = Regexp.last_match(1)
              value = Regexp.last_match(2)
              if environment.include?(env_name) || environment.include?(env_name.to_sym)
                Puppet.warning("Overriding environment setting '#{env_name}' with '#{value}'")
              end
              environment[env_name] = value
            else
              Puppet.warning("Cannot understand environment setting #{setting.inspect}")
            end
          end
        end
        # Convert the Ruby Hashtable into PowerShell syntax
        exec_environment_variables = '@{'
        unless environment.empty?
          environment.each do |name, value|
            # Powershell escapes single quotes inside a single quoted string by just adding
            # another single quote i.e. a value of foo'bar turns into 'foo''bar' when single quoted
            ps_name = name.gsub('\'', '\'\'')
            ps_value = value.gsub('\'', '\'\'')
            exec_environment_variables += " '#{ps_name}' = '#{ps_value}';"
          end
        end
        exec_environment_variables += '}'

        # if the current machine is running less than PS 3.0, prepent the Import-Module Statement.

        # PS side expects Invoke-PowerShellUserCode is always the return value here
        <<-CODE
$params = @{
  Code = @'
#{powershell_code}
'@
  TimeoutMilliseconds = #{timeout_ms}
  WorkingDirectory = "#{working_dir}"
  ExecEnvironmentVariables = #{exec_environment_variables}
}

Invoke-PowerShellUserCode @params
        CODE
      end

      private

      def self.readable?(stream, timeout = 0.5)
        raise Errno::EPIPE unless stream_valid?(stream)
        read_ready = IO.select([stream], [], [], timeout)
        read_ready && stream == read_ready[0][0]
      end

      # when a stream has been closed by handle, but Ruby still has a file
      # descriptor for it, it can be tricky to determine that it's actually dead
      # the .fileno will still return an int, and calling get_osfhandle against
      # it returns what the CRT thinks is a valid Windows HANDLE value, but
      # that may no longer exist
      def self.stream_valid?(stream)
        # when a stream is closed, its obviously invalid, but Ruby doesn't always know
        !stream.closed? &&
          # so calling stat will yield an EBADF when underlying OS handle is bad
          # as this resolves to a HANDLE and then calls the Windows API
          !stream.stat.nil?
      # any exceptions mean the stream is dead
      rescue
        false
      end

      # copied directly from Puppet 3.7+ to support Puppet 3.5+
      def self.wide_string(str)
        # ruby (< 2.1) does not respect multibyte terminators, so it is possible
        # for a string to contain a single trailing null byte, followed by garbage
        # causing buffer overruns.
        #
        # See http://svn.ruby-lang.org/cgi-bin/viewvc.cgi?revision=41920&view=revision
        newstr = str + "\0".encode(str.encoding)
        newstr.encode!('UTF-16LE')
      end

      # mutates the given bytes, removing the length prefixed vaule
      def self.read_length_prefixed_string(bytes)
        # 32-bit integer in Little Endian format
        length = bytes.slice!(0, 4).unpack('V').first
        return nil if length.zero?
        bytes.slice!(0, length).force_encoding(Encoding::UTF_8)
      end

      # bytes is a binary string containing a list of length-prefixed
      # key / value pairs (of UTF-8 encoded strings)
      # this method mutates the incoming value
      def self.ps_output_to_hash(bytes)
        hash = {}
        until bytes.empty?
          hash[read_length_prefixed_string(bytes).to_sym] = read_length_prefixed_string(bytes)
        end

        hash
      end

      # 1 byte command identifier
      #     0 - Exit
      #     1 - Execute
      def pipe_command(command)
        case command
        when :exit
          "\x00"
        when :execute
          "\x01"
        end
      end

      # Data format is:
      # 4 bytes - Little Endian encoded 32-bit integer length of string
      #           Intel CPUs are little endian, hence the .NET Framework typically is
      # variable length - UTF8 encoded string bytes
      def pipe_data(data)
        msg = data.encode(Encoding::UTF_8)
        # https://ruby-doc.org/core-1.9.3/Array.html#method-i-pack
        [msg.bytes.length].pack('V') + msg.force_encoding(Encoding::BINARY)
      end

      def write_pipe(input)
        # for compat with Ruby 2.1 and lower, its important to use syswrite and not write
        # otherwise the pipe breaks after writing 1024 bytes
        written = @pipe.syswrite(input)
        @pipe.flush

        if written != input.length
          msg = "Only wrote #{written} out of #{input.length} expected bytes to PowerShell pipe"
          raise Errno::EPIPE, msg
        end
      end

      def read_from_pipe(pipe, timeout = 0.1)
        if self.class.readable?(pipe, timeout)
          l = pipe.readpartial(4096)
          Puppet.debug "#{Time.now} PIPE> #{l}"
          # since readpartial may return a nil at EOF, skip returning that value
          yield l unless l.nil?
        end

        nil
      end

      def drain_pipe_until_signaled(pipe, signal)
        output = []

        read_from_pipe(pipe) { |s| output << s } while signal.locked?

        # there's ultimately a bit of a race here
        # read one more time after signal is received
        read_from_pipe(pipe, 0) { |s| output << s } while self.class.readable?(pipe)

        # string has been binary up to this point, so force UTF-8 now
        (output == []) ?
          [] :
          [output.join('').force_encoding(Encoding::UTF_8)]
      end

      def read_streams
        pipe_done_reading = Mutex.new
        pipe_done_reading.lock
        start_time = Time.now

        stdout_reader = Thread.new { drain_pipe_until_signaled(@stdout, pipe_done_reading) }
        stderr_reader = Thread.new { drain_pipe_until_signaled(@stderr, pipe_done_reading) }
        pipe_reader = Thread.new(@pipe) do |pipe|
          # read a Little Endian 32-bit integer for length of response
          expected_response_length = pipe.sysread(4).unpack('V').first
          return nil if expected_response_length.zero?

          # reads the expected bytes as a binary string or fails
          pipe.sysread(expected_response_length)
        end

        Puppet.debug "Waited #{Time.now - start_time} total seconds."

        # block until sysread has completed or errors
        begin
          output = pipe_reader.value
          output = self.class.ps_output_to_hash(output) unless output.nil?
        ensure
          # signal stdout / stderr readers via mutex
          # so that Ruby doesn't crash waiting on an invalid event
          pipe_done_reading.unlock
        end

        # given redirection on PowerShell side, this should always be empty
        stdout = stdout_reader.value

        [
          output,
          (stdout == []) ? nil : stdout.join(''), # native stdout
          stderr_reader.value # native stderr
        ]
      ensure
        # failsafe if the prior unlock was never reached / Mutex wasn't unlocked
        pipe_done_reading.unlock if pipe_done_reading.locked?
        # wait for all non-nil threads to see mutex unlocked and finish
        [pipe_reader, stdout_reader, stderr_reader].compact.each(&:join)
      end

      def exec_read_result(powershell_code)
        write_pipe(pipe_command(:execute))
        write_pipe(pipe_data(powershell_code))
        read_streams
      # if any pipes are broken, the manager is totally hosed
      # bad file descriptors mean closed stream handles
      # EOFError is a closed pipe (could be as a result of tearing down process)
      rescue Errno::EPIPE, Errno::EBADF, EOFError => e
        @usable = false
        return nil, nil, [e.inspect, e.backtrace].flatten
      # catch closed stream errors specifically
      rescue IOError => ioerror
        raise unless ioerror.message.start_with?('closed stream')
        @usable = false
        return nil, nil, [ioerror.inspect, ioerror.backtrace].flatten
      end
    end
  end
end
