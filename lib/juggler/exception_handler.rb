module Juggler

  # a utility method that should only be used internally. don't call this; it
  # should only be called once by the Config class and you can get/set it there.
  # returns a mapping from exception classes to http status codes
  #-----------------------------------------------------------------------------
  def self.codes_for_exception_classes
    classes = {
      # These are standard errors in rails / ruby
      NameError =>      "503",
      TypeError =>      "503",
      RuntimeError =>   "500",
      ArgumentError =>  "500",
      # the default mapping for an unrecognized exception class
      :default => "500"
    }

    # from exception_notification gem:
    # Highly dependent on the verison of rails, so we're very protective about these'
    classes.merge!({ ActionView::TemplateError => "500"})             if defined?(ActionView)       && ActionView.const_defined?(:TemplateError)
    classes.merge!({ ActiveRecord::RecordNotFound => "400" })         if defined?(ActiveRecord)     && ActiveRecord.const_defined?(:RecordNotFound)
    classes.merge!({ ActiveResource::ResourceNotFound => "404" })     if defined?(ActiveResource)   && ActiveResource.const_defined?(:ResourceNotFound)

    # from exception_notification gem:
    if defined?(ActionController)
      classes.merge!({ ActionController::UnknownController => "404" })          if ActionController.const_defined?(:UnknownController)
      classes.merge!({ ActionController::MissingTemplate => "404" })            if ActionController.const_defined?(:MissingTemplate)
      classes.merge!({ ActionController::MethodNotAllowed => "405" })           if ActionController.const_defined?(:MethodNotAllowed)
      classes.merge!({ ActionController::UnknownAction => "501" })              if ActionController.const_defined?(:UnknownAction)
      classes.merge!({ ActionController::RoutingError => "404" })               if ActionController.const_defined?(:RoutingError)
      classes.merge!({ ActionController::InvalidAuthenticityToken => "405" })   if ActionController.const_defined?(:InvalidAuthenticityToken)
    end

    return classes
  end

  # class that holds configuration for the exception handling logic. may also
  # include a helper method or two, but the main interaction with
  # ExceptionHandler is setting and getting config, e.g.
  #
  # Juggler::ExceptionHandler.configure do |handler_config|
  #   handler_config.merge! :key => value
  # end
  #-----------------------------------------------------------------------------
  class ExceptionHandler

    # the default configuration
    @@config ||= {
      :app_name => '',
      :handle_local_errors => false,
      :handle_public_errors => true,
      # ignored if :handle_local_errors is false
      :notify_on_local_error => false,
      # ignored if :handle_public_errors is false
      :notify_on_public_error => true,
      :notify_on_background_error => true,
      :delayed_job_for_controller_errors => false,
      :delayed_job_for_non_controller_errors => false,
  
      # add/remove from this list as desired in environment configuration
      :error_class_status_codes => Juggler::codes_for_exception_classes,
      :notify_exception_classes => %w(),
      :notify_status_codes => %w( 405 500 503 ),
      :error_template_dir => File.join(RAILS_ROOT, 'app', 'views', 'error'),
      :error_class_html_templates => {},
      :error_class_js_templates => {},
      :default_error_template => '',
      :codes_for_exception_classes => Juggler::codes_for_exception_classes,
      # these filter out any HTTP params that are undesired
      :request_env_to_skip => [ /^rack\./,
                                "action_controller.rescue.request",
                                "action_controller.rescue.response" ],
      # mapping from exception classes to templates (if desired), express
      # in absolute paths. use wildcards like on cmd line (glob-like), NOT
      # regexp-style

      # just DON'T change this!
      :absolute_last_resort_default_error_template =>
        File.join(JUGGLER_ROOT,'rails','app','views','juggler','500.html')

      # TODO: could also add manual mappings from status_codes to templates...
    }

    cattr_accessor :config

    # allows for overriding default configuration settings.
    # in your environment.rb or environments/<env name>.rb, use a block that
    # accepts one argument
    # * recommend against naming it 'config' as you will probably be calling it
    #   within the config block in env.rb...):
    # * note that some of the config values are arrays or hashes; you can
    #   overwrite them completely, delete or insert/merge new entries into the
    #   default values as you see fit...but in most cases, recommend AGAINST
    #   overwriting the arrays/hashes completely unless you don't want to
    #   take advantage of lots of out-of-the-box config
    #
    # Juggler::ExceptionHandler.configure do |handler_config|
    #   handler_config[:key1] = value1
    #   handler_config[:key2] = value2
    #   handler_config[:key_for_a_hash].merge! :subkey => value
    #   handler_config[:key_for_an_array] << another_value
    # end
    #
    # OR
    #
    # Juggler::ExceptionHandler.configure do |handler_config|
    #   handler_config.merge! :key1 => value1,
    #                         :key2 => value2,
    #   handler_config[:key_for_a_hash].merge! :subkey => value
    #   handler_config[:key_for_an_array] << another_value
    # end
    # 
    # NOTE: sure, you can change this configuration on the fly in your app, but
    # we don't recommend it. plus, if you do and you're using delayed_job, there
    # may end up being configuration differences between the rails process and
    # the delayed_job process, resulting in unexpected behavior. so recommend
    # you just modify this in the environment config files...or if you're doing
    # something sneaky, you're on your own.
    #-----------------------------------------------------------------------------
    def self.configure(&block)
      yield @@config
    end


    # translate the exception class to an http status code, using default
    # code (set in config) if the exception class isn't excplicitly mapped
    # to a status code in config
    #---------------------------------------------------------------------------
    def self.status_code_for_exception(exception)
      if exception.respond_to?(:status_code)
        return exception.status_code
      else
        return config[:error_class_status_codes][exception.class] ||
               config[:error_class_status_codes][:default]
      end
    end

  # TODO: allow non-controller cases...maybe copy the cool approach to giving
  # a method like notify_on_error { ... } that runs the block and notifies
  # if an exception bubbles up

  # TODO: allow configuring different settings for each controller? not too
  # important for us...

  end # end ExceptionHandler class

  ##############################################################################
  # actual exception handling code
  ##############################################################################

  # make all of these instance methods also module functions
  module_function

  # execute the code block passed as an argument, and follow notification
  # rules if an exception bubbles out of the block.
  #
  # return value:
  #   * if an exception bubbles out of the block, the exception is re-raised to
  #     calling code.
  #   * otherwise, returns nil
  #-----------------------------------------------------------------------------
  def notify_on_error(proc_name = nil, &block)
    begin
      yield
    rescue => exception
      options = {}
      options.merge! :proc_name => proc_name unless proc_name.nil?
      handle_exception(exception, options)
    end

    return nil
  end

  # the main exception-handling method. decides whether to notify or not,
  # whether to render an error page or not, and to make it happen.
  #
  # arguments:
  #   - exception: the exception that was caught
  #
  # options:
  #   :request: the request object (if any) that resulted in the exception
  #   :render_errors: boolean indicating if an error page should be rendered
  #                   or not (Rails only)
  #   :proc_name: a string representation of the process/app that was running
  #               when the exception was raised. default value is
  #               Juggler::ExceptionHandler.config[:app_name].
  #-----------------------------------------------------------------------------
  def handle_exception(exception, options = {})
    request = options[:request]
    render_errors = options[:render_errors] || false
    proc_name = options[:proc_name] || config[:app_name]

    status_code = Juggler::ExceptionHandler.status_code_for_exception(exception)
    request_data = request_data_from_request(request) unless request.nil?

    puts "\n\nTODO: status code is: #{status_code}"
#    puts "TODO: request data:"
#    puts request_data.to_yaml
#    puts "\n\n"

    if notify_on_exception?(exception, status_code)
      if notify_with_delayed_job?
        # don't pass in request as it contains not-easily-serializable stuff
        Juggler::ExceptionNotifier.send_later(:deliver_exception_notification,
                                              exception,
                                              proc_name,
                                              exception.backtrace,
                                              status_code,
                                              request_data)
      else
        Juggler::ExceptionNotifier.deliver_exception_notification(exception,
                                                         proc_name,
                                                         exception.backtrace,
                                                         status_code,
                                                         request_data,
                                                         request)
      end
    end

    log_exception(exception, request_data, status_code)

    if render_errors

      puts "\n\nTODO: rendering error"

      render_error_template(exception, status_code)

    else
      puts "\n\nTODO: NOT rendering error"

    end
  end


  # determine if the app is configured to notify for the given exception or
  # status code
  #-----------------------------------------------------------------------------
  def notify_on_exception?(exception, status_code = nil)
    # first determine if we're configured to notify given the context of the
    # exception
    if self.respond_to?(:local_request?)
      if (local_request? && config[:notify_on_local_error]) ||
          (!local_request? && config[:notify_on_public_error])
        notify = true
      else
        notify = false
      end
    else
      notify = config[:notify_on_background_error]
    end

    # now if config says notify in this case, check if we're configured to
    # notify for this exception or this status code
    return notify &&
      (config[:notify_exception_classes].include?(exception.class) ||
       config[:notify_status_codes].include?(status_code))
  end

  # determine if email should be sent with delayed job or not (delayed job
  # must be installed and config set to use delayed job
  #-----------------------------------------------------------------------------
  def notify_with_delayed_job?
    use_dj = false

    if self.is_a?(ActionController::Base)
      if config[:delayed_job_for_controller_errors] &&
          ExceptionNotifier.respond_to?(:send_later)
        use_dj = true
      else
        use_dj = false
      end
    else
      if config[:delayed_job_for_non_controller_errors] &&
          ExceptionNotifier.respond_to?(:send_later)
        use_dj = true
      else
        use_dj = false
      end
    end

    return use_dj
  end


  # TODO: add any non-controller method as module_methods as well...



end
