require 'rubygems' if RUBY_VERSION < '1.9'
require 'win32/service'
require 'rbconfig'

include Win32

SERVICE_NAME = 'AnyDBAPI'

raise ArgumentError, "No arguments provided" unless ARGV[0]

case ARGV[0].downcase
	when 'install'

		if !(Service.exists?(SERVICE_NAME))
			# Create a new service
			
			rubyexe = File.join(RbConfig::CONFIG["bindir"],RbConfig::CONFIG["ruby_install_name"] + RbConfig::CONFIG["EXEEXT"])
			filename = File.join(File.expand_path(File.dirname(__FILE__)), "servicedaemon.rb")

			Service.create({
			  :service_name       => SERVICE_NAME,
			  :service_type       => Service::WIN32_OWN_PROCESS,
			  :description        => 'Stellarise API for running database queries',
			  :start_type         => Service::AUTO_START,
			  :error_control      => Service::ERROR_NORMAL,
			  :binary_path_name   => rubyexe + ' ' + filename,
			  :load_order_group   => 'Network',
			  :dependencies       => ['W32Time','Schedule'],
			  :display_name       => SERVICE_NAME
			})

			puts SERVICE_NAME + " service installed."
		else
			puts SERVICE_NAME + " service already exists!"
		end	
	when 'uninstall', 'remove', 'delete'
		if (Service.exists?(SERVICE_NAME))
			if (Service.status(SERVICE_NAME).current_state == 'stopped') 
				# delete the service
				Service.delete(SERVICE_NAME)
				puts SERVICE_NAME + " service removed."
			else
				puts SERVICE_NAME + " is running. Please stop the service first and then retry uninstalling."
			end
		else
			puts SERVICE_NAME + " service not found!"
		end
	else
      puts "This program installs or uninstalls the " + SERVICE_NAME + " service. The program needs to be run with either of the following options:"
      puts "	install : to install the service"
      puts "	uninstall/remove/delete: to delete the service"
end
