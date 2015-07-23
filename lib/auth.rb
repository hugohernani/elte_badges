require 'sinatra/base'
require 'typhoeus'

module Sinatra
  module Auth
    def self.registered(app)
      app.helpers Auth::Helpers

      app.post "/badge_check" do
        error("This is an old launch. You need to re-configure your LTI settings")
      end

      # LTI tool launch, makes sure we're oauth-good and then redirects to the magic page
      app.post "/placement_launch" do
        get_org
        key = params['oauth_consumer_key']
        tool_config = ExternalConfig.first(:config_type => 'lti', :value => key)
        if !tool_config
          halt 400, error("Invalid tool launch - unknown tool consumer")
        end
        secret = tool_config.shared_secret
        host = params['custom_canvas_api_domain']
        host_return_url = ""
        if host && params['launch_presentation_return_url']
          host_return_url ||= params['launch_presentation_return_url'].split(/\//)[2]
        end

        host ||= params['tool_consumer_instance_guid'].split(/\./)[1..-1].join(".") if params['tool_consumer_instance_guid'] && params['tool_consumer_instance_guid'].match(/\./)
        if !host
          halt 400, error("This app appears to have been misconfigured, please contact your instructor or administrator. App should receive custom_canvas_api_domain parameter but isn't.")
        end
        domain = Domain.first_or_new(:host => host)
        domain.name = (params['tool_consumer_instance_name'] || "")[0, 30]
        domain.save
        provider = IMS::LTI::ToolProvider.new(key, secret, params)
        if !params['custom_canvas_user_id']
          halt 400, error("This app appears to have been misconfigured, please contact your instructor or administrator. App must be launched with public permission settings.")
        end
        if !params['lis_person_contact_email_primary']
          halt 400, error("This app appears to have been misconfigured, please contact your instructor or administrator. Email address is required on user launches.")
        end
        if provider.valid_request?(Sinatra::Request.new(request.env['badges.original_env']))
          badgeless_placement = params['custom_show_all'] || params['custom_show_course'] || params['ext_content_intended_use'] == 'navigation' || params['picker']
          unless badgeless_placement
            if !params['custom_canvas_course_id']
              halt 400, error("This app appears to have been misconfigured, please contact your instructor or administrator. Course must be a Canvas course, and launched with public permission settings.")
            end
            bc = BadgePlacementConfig.first_or_new(:placement_id => params['resource_link_id'], :domain_id => domain.id, :course_id => params['custom_canvas_course_id'])
            bc.external_config_id ||= tool_config.id
            bc.organization_id = tool_config.organization_id if !bc.id
            bc.organization_id ||= @org.id
            bc.settings ||= {}
            bc.settings['course_url'] = "#{BadgeHelper.protocol}://" + host + "/courses/" + params['custom_canvas_course_id']
            bc.settings['prior_resource_link_id'] = params['custom_prior_resource_link_id'] if params['custom_prior_resource_link_id']
            bc.settings['pending'] = true if !bc.id

            unless bc.settings['badge_config_already_checked']
              bc.settings['badge_config_already_checked'] = true
              if params['badge_reuse_code']
                specified_badge_config = BadgeConfig.first(:reuse_code => params['badge_reuse_code'])
                if specified_badge_config && bc.badge_config != specified_badge_config && !bc.configured?
                  bc.set_badge_config(specified_badge_config)
                end
              else
                old_style_badge_config = BadgeConfig.first(:placement_id => params['resource_link_id'], :domain_id => domain.id, :course_id => params['custom_canvas_course_id'])
                if old_style_badge_config
                  bc.set_badge_config(old_style_badge_config)
                end
              end
            end
            if !bc.badge_config
              conf = BadgeConfig.new(:organization_id => bc.organization_id)
              conf.settings = {}
              conf.settings['badge_name'] = params['badge_name'] if params['badge_name']
              conf.reuse_code = params['badge_reuse_code'] if params['badge_reuse_code'] && params['badge_reuse_code'].length > 20
              conf.save
              bc.badge_config = conf
            end
            bc.save
            session["launch_badge_placement_config_id"] = bc.id
            @bc = bc
          end

          user_id = params['custom_canvas_user_id']

          user_config = UserConfig.first(:user_id => user_id, :domain_id => domain.id)

          session["user_id"] = user_id
          session["user_image"] = params['user_image']
          session["launch_placement_id"] = params['resource_link_id']
          session["launch_course_id"] = params['custom_canvas_course_id']
          session["permission_for_#{params['custom_canvas_course_id']}"] = 'view'
          session['email'] = params['lis_person_contact_email_primary']

          # TODO: something akin to this parameter needs to be sent in order to
          # tell the difference between Canvas Cloud and Canvas CV instances.
          # Otherwise I can't tell the difference between global_user_id 5 from
          # Cloud as opposed to from CV.
          session['source_id'] = params['custom_canvas_system_id'] || 'cloud'
          session['name'] = params['lis_person_name_full']
          # check if they're a teacher or not
          session["permission_for_#{params['custom_canvas_course_id']}"] = 'edit' if provider.roles.include?('instructor') || provider.roles.include?('contentdeveloper') || provider.roles.include?('urn:lti:instrole:ims/lis/administrator') || provider.roles.include?('administrator')
          session['domain_id'] = domain.id.to_s
          session['params_stash'] = hash_slice(params, 'custom_show_all', 'custom_show_course', 'ext_content_intended_use', 'picker', 'custom_canvas_course_id', 'launch_presentation_return_url', 'ext_content_return_url')
          session['custom_show_all'] = params['custom_show_all']

          # if we already have an oauth token then make sure it works
          json = CanvasAPI.api_call("/api/v1/users/self/profile", user_config) if user_config
          if user_config && json && json['id']
            user_config.image = params['user_image']
            user_config.save
            session['user_id'] = user_config.user_id

            launch_redirect((@bc && @bc.id), domain.id, user_config.user_id, params)
          # otherwise we need to do the oauth dance for this user
          else
            oauth_dance(request, host)
          end
        else
          return error("Invalid tool launch - invalid parameters")
        end
      end

      app.get "/oauth_success" do
        get_org
        if !session['domain_id'] || !session['user_id'] || !session['source_id']
          halt 400, erb(:session_lost)
        end
        domain = Domain.first(:id => session['domain_id'])
        return_url = "#{protocol}://#{request.env['badges.original_domain']}/oauth_success"
        code = params['code']
        url = "#{protocol}://#{domain.host}/login/oauth2/token"
        secure_connection = !@org.settings['insecure']

        response = Typhoeus.post(url, body: {
          :client_id => oauth_config.value,
          :code => code,
          :client_secret => oauth_config.shared_secret,
          :redirect_uri => return_url
        }, ssl_verifypeer: false)

        if response.code == 0
          return error("Error authenticating user, please contact the system admin")
        end
        json = JSON.parse(response.body) rescue nil

        if json && json['access_token']
          user_config = UserConfig.first_or_new(:user_id => json['user']['id'], :domain_id => domain.id)
          user_config.access_token = json['access_token']
          user_config.name = session['name']
          user_config.image = session['user_image']
          user_config.global_user_id = session['source_id'] + "_" + json['user']['id'].to_s
          user_config.email = session['email']

          user_config.save
          params_stash = session['params_stash']
          launch_badge_placement_config_id = session['launch_badge_placement_config_id']
          launch_course_id = session["launch_course_id"]
          permission = session["permission_for_#{launch_course_id}"]
          name = session['name']
          email = session['email']
          locale = session['locale']

          session.destroy
          session['user_id'] = user_config.user_id.to_s
          session['domain_id'] = user_config.domain_id.to_s.to_i
          session["permission_for_#{launch_course_id}"] = permission
          session['name'] = name
          session['email'] = email
          session['locale'] = locale

          launch_redirect(launch_badge_placement_config_id, user_config.domain_id, user_config.user_id, params_stash)
        else
          return error("Error retrieving access token")
        end
      end

      app.get "/login" do
        get_org
        request_token = consumer.get_request_token(:oauth_callback => "#{request.scheme}://#{request.env['badges.domain']}/login_success")
        if request_token.token && request_token.secret
          session[:oauth_token] = request_token.token
          session[:oauth_token_secret] = request_token.secret
        else
          return "Authorization failed"
        end
        redirect to("https://api.twitter.com/oauth/authenticate?oauth_token=#{request_token.token}")
      end

      app.get "/login_success" do
        get_org
        verifier = params[:oauth_verifier]
        if params[:oauth_token] != session[:oauth_token]
          return "Authorization failed"
        end
        request_token = OAuth::RequestToken.new(consumer,
          session[:oauth_token],
          session[:oauth_token_secret]
        )
        access_token = request_token.get_access_token(:oauth_verifier => verifier)
        screen_name = access_token.params['screen_name']

        if !screen_name
          return "Authorization failed"
        end


        @org = Organization.first(:host => request.env['badges.original_domain'], :order => :id)
        @org ||= Organization.first(:old_host => request.env['badges.original_domain'], :order => :id)
        @conf = ExternalConfig.generate(screen_name)

        hash = @conf.confirmation
        redirect to("/token?id=#{@conf.id}&confirmation=#{hash}")
      end

      app.get "/session_fix" do
        get_org
        session['has_session'] = true
        erb :session_fixed
      end
    end
    module Helpers
      def consumer
        consumer ||= OAuth::Consumer.new(twitter_config.value, twitter_config.shared_secret, {
          :site => "https://api.twitter.com",
          :request_token_path => "/oauth/request_token",
          :access_token_path => "/oauth/access_token",
          :authorize_path=> "/oauth/authorize",
          :signature_method => "HMAC-SHA1"
        })
      end

      def hash_slice(hash, *keys)
        keys.each_with_object({}){|k, h| h[k] = hash[k]}
      end

      def launch_redirect(config_id, domain_id, user_id, params)
        params ||= {}
        if params['custom_show_all']
          redirect to("#{request.env['badges.path_prefix']}/badges/all/#{domain_id}/#{user_id}")
        elsif params['custom_show_course']
          redirect to("#{request.env['badges.path_prefix']}/badges/course/#{params['custom_canvas_course_id']}")
        elsif params['ext_content_intended_use'] == 'navigation' || params['picker']
          return_url = params['ext_content_return_url'] || params['launch_presentation_return_url'] || ""
          redirect to("#{request.env['badges.path_prefix']}/badges/pick?return_url=#{CGI.escape(return_url)}")
        else
          if !config_id
            halt 400, erb(:session_lost)
          end
          redirect to("#{request.env['badges.path_prefix']}/badges/check/#{config_id}/#{user_id}")
        end
      end

      def twitter_config
        @@twitter_config ||= ExternalConfig.first(:config_type => 'twitter_for_login')
      end
    end
  end

  register OAuth
end
