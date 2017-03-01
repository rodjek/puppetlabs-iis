require File.join(File.dirname(__FILE__), '../../../puppet/provider/iis_powershell')

Puppet::Type.type(:iis_application_pool).provide(:webadministration_85, parent: :webadministration) do
  confine    :iis_version     => ['8.5']
  defaultfor :operatingsystem => :windows

  has_feature :idle_timeout_action
end
