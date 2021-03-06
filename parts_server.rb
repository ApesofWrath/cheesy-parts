# Copyright 2012 Team 254. All Rights Reserved.
# @author pat@patfairbank.com (Patrick Fairbank)
#
# The main class of the parts management web server.

require "active_support/time"
require "cgi"
require "dedent"
require "eventmachine"
require "json"
require "pathological"
require "pony"
require "sinatra/base"
require "google/apis/oauth2_v2"
require "google/api_client/client_secrets"
require "slack-ruby-client"

require "models"

module CheesyParts
  class Server < Sinatra::Base
    use Rack::Session::Cookie, :key => "rack.session", :expire_after => 3600

    # Enforce authentication for all routes except login and user registration.
    before do
      @user = User[session[:user_id]]
      authenticate! unless ["/login", "/register"].include?(request.path)
      if CheesyCommon::Config.enable_slack_integrations
        Slack.configure do |config|
          config.token = CheesyCommon::Config.slack_api_token
        end
        $slack_client = Slack::Web::Client.new
        $slack_client.auth_test
      end
    end

    def authenticate!
      redirect "/login?redirect=#{request.path}" if @user.nil?
      if @user.enabled == 0
        session[:user_id] = nil
        redirect "/login?disabled=1"
      end
    end

    def require_permission(user_permitted)
      halt(400, "Insufficient permissions.") unless user_permitted
    end

    # Helper function to send an e-mail through Gmail's SMTP server.
    def send_email(to, subject, body)
      # Run this asynchronously using EventMachine since it takes a couple of seconds.
      EM.defer do
        Pony.mail(:from => "Cheesy Parts <#{CheesyCommon::Config.gmail_user}>", :to => to,
                  :subject => subject, :body => body, :via => :smtp,
                  :via_options => { :address => "smtp.gmail.com", :port => "587",
                                    :enable_starttls_auto => true,
                                    :user_name => CheesyCommon::Config.gmail_user.split("@").first,
                                    :password => CheesyCommon::Config.gmail_password,
                                    :authentication => :plain, :domain => "localhost.localdomain" })
      end
    end

    get "/" do
      redirect "/projects"
    end

    get "/login" do
      redirect "/logout" if @user
      @redirect = params[:redirect] || "/"

      if CheesyCommon::Config.enable_wordpress_auth
        member = CheesyCommon::Auth.get_user(request)
        if member.nil?
          redirect "#{CheesyCommon::Config.members_url}?site=parts&path=#{request.path}"
        else
          user = User[:wordpress_user_id => member.id]
          unless user
            user = User.create(:wordpress_user_id => member.id, :first_name => member.name[1],
                               :last_name => member.name[0], :permission => "editor", :enabled => 1,
                               :email => member.email, :password => "", :salt => "")
          end
          session[:user_id] = user.id
          redirect @redirect
        end
      end

      if CheesyCommon::Config.enable_google_oauth
        if params[:code]
          $auth_client.code = request['code']
          $auth_client.fetch_access_token!
          oauth_service = Google::Apis::Oauth2V2::Oauth2Service.new
          oauth_service.authorization = $auth_client
          profile = oauth_service.get_userinfo(:fields => 'email,id,name')
          unless profile.email.include? CheesyCommon::Config.user_domain_whitelist
            redirect "/"
          end
          if profile.nil?
            @alert = "No person!"
          else
            user = User[:wordpress_user_id => profile.id[0,7]]
            unless user
              user = User.create(:wordpress_user_id => profile.id[0,7], :first_name => profile.name.split(" ")[0],
                                 :last_name => profile.name.split(" ")[1], :permission => "read-only", :enabled => 1,
                                 :email => profile.email, :password => "", :salt => "")
            end
          end
          session[:user_id] = user.id

          redirect @redirect
        elsif params[:error]
          @alert = "Error!"
        else
          client_secrets = Google::APIClient::ClientSecrets.load
          $auth_client = client_secrets.to_authorization
          $auth_client.update!(
            :scope => ['profile', 'openid', 'email'],
            :redirect_uri => CheesyCommon::Config.oauth_callback_url
          )
          auth_uri = $auth_client.authorization_uri.to_s
          redirect auth_uri
        end
      end

      if params[:failed] == "1"
        @alert = "Invalid e-mail address or password."
      elsif params[:disabled] == "1"
        @alert = "Your account is currently disabled."
      end
      erb :login
    end

    post "/login" do
      user = User.authenticate(params[:email], params[:password])
      redirect "/login?failed=1" if user.nil?
      redirect "/login?disabled=1" if user.enabled == 0
      session[:user_id] = user.id
      redirect params[:redirect]
    end

    get "/logout" do
      session[:user_id] = nil
      if CheesyCommon::Config.enable_wordpress_auth
        redirect "#{CheesyCommon::Config.members_url}/logout"
      else
        redirect "/login"
      end
    end

    # Projects
    get "/new_project" do
      require_permission(@user.can_administer?)
      erb :new_project
    end

    get "/projects" do
      erb :projects
    end

    post "/projects" do
      require_permission(@user.can_administer?)

      # Check parameter existence and format.
      halt(400, "Missing project name.") if params[:name].nil? || params[:name] == ""
      halt(400, "Missing part number prefix.") if params[:part_number_prefix].nil? || params[:part_number_prefix] == ""

      project = Project.create(:name => params[:name], :part_number_prefix => params[:part_number_prefix], :hide_dashboards => false)
      redirect "/projects/#{project.id}"
    end

    # Check that it is a valid project id
    before "/projects/:id*" do
      @project = Project[params[:id]]
      halt(400, "Invalid project.") if @project.nil?
    end

    get "/projects/:id" do
      if ["type", "name", "parent_part_id", "status", "assignee"].include?(params[:sort])
        @part_sort = params[:sort].to_sym
      else
        @part_sort = :part_number
      end
      erb :project
    end

    get "/projects/:id/edit" do
      require_permission(@user.can_administer?)
      erb :project_edit
    end

    post "/projects/:id/edit" do
      require_permission(@user.can_administer?)

      @project.name = params[:name] if params[:name]
      if params[:part_number_prefix]
        @project.part_number_prefix = params[:part_number_prefix]
      end
      @project.save
      redirect "/projects/#{params[:id]}"
    end

    get "/projects/:id/delete" do
      require_permission(@user.can_administer?)

      erb :project_delete
    end

    post "/projects/:id/delete" do
      require_permission(@user.can_administer?)
      DB[:tasks].where(project_id: params[:id])
      @project.delete
      redirect "/projects"
    end

    get "/projects/:id/dashboard" do
      erb :dashboard
    end

    get "/projects/:id/dashboard/parts" do
      @status = params[:status] if Part::STATUS_MAP.has_key?(params[:status])
      erb :dashboard_parts
    end

    get "/projects/:id/new_part" do
      require_permission(@user.can_edit?)

      @parent_part_id = params[:parent_part_id]
      @type = params[:type] || "part"
      halt(400, "Invalid part type.") unless Part::PART_TYPES.include?(@type)
      erb :new_part
    end

    # New Milestone
    get "/projects/:id/new_milestone" do
      require_permission(@user.can_edit?)

      erb :new_milestone
    end
    
    # Created Milestone
    post "/milestones" do
      require_permission(@user.can_edit?)

      # Check parameter existence and format.
      halt(400, "Missing milestone name.") if params[:name].nil? || params[:name].empty?
      if params[:project_id] && params[:project_id] !~ /^\d+$/
        halt(400, "Invalid project ID.")
      end

      project = Project[params[:project_id].to_i]
      halt(400, "Invalid project.") if project.nil?
      halt(400, "Missing deadline.") if params[:deadline].nil? || params[:deadline].empty?
      halt(400, "Missing start date.") if params[:start_date].nil? || params[:start_date].empty?
      halt(400, "Start date must be before deadline.") if params[:start_date].to_date >= params[:deadline].to_date  

      begin
        milestone = Milestone.create(:name => params[:name], :project_id => params[:project_id], :deadline => params[:deadline], :start_date => params[:start_date], :notes => params[:notes], :status => "in_progress") 
        milestone.save
        rescue Sequel::UniqueConstraintViolation
          halt(400, "Milestone already exists.")
      end

      redirect "/milestones/#{milestone.id}"
    end     

    # Milestone
    get "/milestones/:id" do
      @milestone = Milestone[params[:id]]
      halt(400, "Invalid milestone.") if @milestone.nil?
      erb :milestone
    end

    get "/milestones/:id/delete" do
      require_permission(@user.can_edit?)

      @milestone = Milestone[params[:id]]
      halt(400, "Invalid milestone.") if @milestone.nil?
      @referrer = request.referrer
      erb :milestone_delete
    end

    post "/milestones/:id/delete" do
      require_permission(@user.can_edit?)

      @milestone = Milestone[params[:id]]
      project_id = @milestone.project_id
      halt(400, "Invalid task.") if @milestone.nil?

      @milestone.delete

      params[:referrer] = nil if params[:referrer] =~ /\/milestones\/#{params[:id]}$/
      redirect params[:referrer] || "/projects/#{project_id}"
    end

    get "/milestones/:id/edit" do
      require_permission(@user.can_edit?)

      @milestone = Milestone[params[:id]]
      halt(400, "Invalid milestone.") if @milestone.nil?
      @referrer = request.referrer
      erb :milestone_edit
    end

    post "/milestones/:id/edit" do
      require_permission(@user.can_edit?)

      @milestone = Milestone[params[:id]]
      # Check parameter existence and format.
      halt(400, "Missing milestone name.") if params[:name].nil? || params[:name].empty?
      halt(400, "Start date must be before deadline.") if params[:start_date].to_date >= params[:deadline].to_date if params[:start_date]

      @milestone.name = params[:name].gsub("\"", "&quot;") if params[:name]
      if params[:status]
        halt(400, "Invalid status.") unless Milestone::STATUS_MAP.include?(params[:status])
        old_task_status = @milestone.status
        new_task_status = params[:status]
        @milestone.status = params[:status]
      end
      @milestone.start_date = params[:start_date] if params[:start_date]
      @milestone.deadline = params[:deadline] if params[:deadline]
      @milestone.notes = params[:notes] if params[:notes]
      @milestone.save

      redirect params[:referrer] || "/milestones/#{params[:id]}" unless !params[:redirect].nil? && params[:redirect]
    end

    # New Task
    get "/projects/:id/new_task" do
      require_permission(@user.can_edit?)
      erb :new_task
    end

    # Create Task
    post "/tasks" do
      require_permission(@user.can_edit?)

      # Check parameter existence and format.
      halt(400, "Missing task name.") if params[:name].nil? || params[:name].empty?
      project = Project[params[:project_id].to_i]
      halt(400, "Invalid project.") if project.nil?
      subteam = Subteam[params[:subteam]]
      halt(400, "Invalid subteam.") if subteam.nil?
      halt(400, "No milestones found. Please create one for this project (#{project.name}).") if params[:milestone_id] == "-1"
      halt(400, "Invalid milestone.") if params[:milestone_id].nil? || params[:milestone_id].empty?
      halt(400, "Missing assignee.") if params[:assignee].nil? || params[:assignee].empty?
      halt(400, "Missing start date.") if params[:start_date].nil? || params[:start_date].empty?
      halt(400, "Missing deadline.") if params[:deadline].nil? || params[:deadline].empty?
      halt(400, "Start date must be before deadline.") if params[:start_date].to_date >= params[:deadline].to_date

      begin
        task = Task.create(:name => params[:name], :project_id => params[:project_id], :deadline => params[:deadline], :assignee => params[:assignee], :milestone_id => params[:milestone_id], :sub_name => params[:subteam], :notes => params[:notes], :per_comp => 0, :dep_task_id => params[:dep_task_id], :start_date => params[:start_date]) 
        task.save
        rescue Sequel::UniqueConstraintViolation
          halt(400, "Task already exists.")
      end

      redirect "/tasks/#{task.id}"
    end     

    # Task
    get "/tasks/:id" do
      @task = Task[params[:id]]
      halt(400, "Invalid task.") if @task.nil?
      erb :task
    end

    get "/tasks/:id/edit" do
      require_permission(@user.can_edit?)

      @task = Task[params[:id]]
      halt(400, "Invalid task.") if @task.nil?
      @referrer = request.referrer
      erb :task_edit
    end

    post "/tasks/:id/edit" do
      require_permission(@user.can_edit?)

      @task = Task[params[:id]]
      # Check parameter existence and format.
      halt(400, "Missing task name.") if params[:name].nil? || params[:name].empty?
      #project = Project[params[:project_id].to_i]
      #halt(400, "Invalid project.") if project.nil?
      #subteam = Subteam[params[:subteam]]
      #halt(400, "Invalid subteam.") if subteam.nil?
      #halt(400, "Invalid milestone.") if params[:milestone_name].nil? || params[:milestone_name].empty?
      #halt(400, "Missing assignee.") if params[:assignee].nil? || params[:assignee].empty?
      #halt(400, "Missing deadline.") if params[:deadline].nil? || params[:deadline].empty?
      halt(400, "Start date must be before deadline.") if params[:start_date].to_date >= params[:deadline].to_date if params[:start_date]

      @task.name = params[:name].gsub("\"", "&quot;") if params[:name]
      @task.assignee = params[:assignee] if params[:assignee]
      @task.sub_name = params[:subteam] if params[:subteam]
      @task.per_comp = params[:per_comp] if params[:per_comp]
      @task.dep_task_id = params[:dep_task_id] if params[:dep_task_id]
      @task.milestone_id = params[:milestone_id] if params[:milestone_id]
      @task.start_date = params[:start_date] if params[:start_date]
      @task.deadline = params[:deadline] if params[:deadline]
      @task.notes = params[:notes] if params[:notes]
      @task.save

      redirect params[:referrer] || "/tasks/#{params[:id]}" unless !params[:redirect].nil? && params[:redirect]
    end   

    get "/tasks/:id/delete" do
      require_permission(@user.can_edit?)

      @task = Task[params[:id]]
      halt(400, "Invalid task.") if @task.nil?
      @referrer = request.referrer
      erb :task_delete
    end

    post "/tasks/:id/delete" do
      require_permission(@user.can_edit?)

      @task = Task[params[:id]]
      project_id = @task.project_id
      halt(400, "Invalid task.") if @task.nil?
      @task.delete
      params[:referrer] = nil if params[:referrer] =~ /\/tasks\/#{params[:id]}$/
      redirect params[:referrer] || "/projects/#{project_id}"
    end

    # Planning
    get "/planning" do
      erb :planning
    end
    
    # Check that it is a valid project id
    before "/planning/:id*" do
      @project = Project[params[:id]]
      halt(400, "Invalid project.") if @project.nil?
    end

    get "/planning/:id" do
      erb :gantt
    end

    # Dashboards
    get "/dashboards" do
      erb :dashboards
    end

    # Parts
    post "/parts" do
      require_permission(@user.can_edit?)

      # Check parameter existence and format.
      halt(400, "Missing project ID.") if params[:project_id].nil? || params[:project_id] !~ /^\d+$/
      halt(400, "Missing part type.") if params[:type].nil?
      halt(400, "Invalid part type.") unless Part::PART_TYPES.include?(params[:type])
      halt(400, "Missing part name.") if params[:name].nil? || params[:name].empty?
      halt(400, "Missing assignee.") if params[:assignee].nil? || params[:assignee].empty?
      if params[:parent_part_id] && params[:parent_part_id] !~ /^\d+$/
        halt(400, "Invalid parent part ID.")
      end

      project = Project[params[:project_id].to_i]
      halt(400, "Invalid project.") if project.nil?
      halt(400, "No milestones found. Please create one for this project (#{project.name}).") if params[:milestone_id] == "-1"

      parent_part = nil
      if params[:parent_part_id]
        parent_part = Part[:id => params[:parent_part_id].to_i, :project_id => project.id,
                           :type => "assembly"]
        halt(400, "Invalid parent part.") if parent_part.nil?
      end

      part = Part.generate_number_and_create(project, params[:type], parent_part)
      part.name = params[:name].gsub("\"", "&quot;")
      part.status = "designing"
      part.source_material = ""
      part.have_material = 0
      part.quantity = ""
      part.cut_length = ""
      part.priority = 1
      part.drawing_created = 0
      part.gcode_created = 0
      part.cnc_part = 0
      part.print_part = 0
      part.drawing_link = ""
      part.gcode_link = ""
      part.assignee = params[:assignee].gsub("\"", "&quot;") if params[:assignee]
      part.milestone_id = params[:milestone_id];
      part.save
      redirect "/parts/#{part.id}"
    end

    get "/parts/:id" do
      @part = Part[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      if ["type", "name", "parent_part_id", "status"].include?(params[:sort])
        @part_sort = params[:sort].to_sym
      else
        @part_sort = :part_number
      end
      erb :part
    end

    get "/parts/:id/edit" do
      require_permission(@user.can_edit?)

      @part = Part[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      @referrer = request.referrer
      erb :part_edit
    end

    post "/parts/:id/edit" do
      require_permission(@user.can_edit?)

      @part = Part[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      halt(400, "Missing part name.") if params[:name] && params[:name].empty?
      halt(400, "No drawing link provided.") if params[:drawing_created] && params[:drawing_link].empty?
      halt(400, "Must provide drawing link to mark as ready to manufacture.") if (params[:status]) && (params[:status].include?("ready")) && (params[:drawing_link].empty?)
      halt(400, "No gcode link provided.") if params[:gcode_created] && params[:gcode_link].empty?
      halt(400, "Must provide gcode link to mark as ready to manufacture.") if (params[:status]) && (params[:status].include?("ready")) && (params[:gcode_link].empty?)
      halt(400, "Must provide source material to mark as ready to manufacture.") if (params[:status]) && (params[:status].include?("ready")) && (params[:source_material].empty?)
      halt(400, "Must provide quantity to mark as ready to manufacture.") if (params[:status]) && (params[:status].include?("ready")) && (params[:quantity].empty?)
      halt(400, "Must provide a milestone.") if params[:milestone_id].nil? || params[:milestone_id].empty?
      @part.name = params[:name].gsub("\"", "&quot;") if params[:name]
      if params[:status]
        halt(400, "Invalid status.") unless Part::STATUS_MAP.include?(params[:status])
        old_part_status = @part.status
        new_part_status = params[:status]
        @part.status = params[:status]
      end

      @part.parent_part_id = params[:parent_part_id]
      @part.milestone_id = params[:milestone_id] if params[:milestone_id]
      @part.notes = params[:notes] if params[:notes]
      @part.source_material = params[:source_material] if params[:source_material]
      @part.have_material = (params[:have_material] == "on") ? 1 : 0 if params[:have_material]
      @part.cut_length = params[:cut_length] if params[:cut_length]
      @part.quantity = params[:quantity] if params[:quantity]
      @part.drawing_created = (params[:drawing_created] == "on" || params[:drawing_link].strip.length > 0) ? 1 : 0 if params[:drawing_created]
      @part.gcode_created = (params[:gcode_created] == "on" || params[:gcode_created].strip.length > 0) ? 1 : 0 if params[:gcode_created]
      @part.priority = params[:priority] if params[:priority]
      @part.cnc_part = (params[:cnc_part] == "on") ? 1 : 0
      @part.print_part = (params[:print_part] == "on") ? 1 : 0
      @part.drawing_link = params[:drawing_link] if params[:drawing_link]
      @part.gcode_link = params[:gcode_link] if params[:gcode_link]
      @part.assignee = params[:assignee] if params[:assignee]
      @part.save

      if CheesyCommon::Config.enable_slack_integrations
        if (new_part_status != old_part_status) && (new_part_status.include?"ready")
          $slack_client.chat_postMessage(:token => CheesyCommon::Config.slack_api_token, :channel => CheesyCommon::Config.slack_parts_room, :text => "New part ready for manufacturing!",
                 :as_user => true, :attachments => [{"fallback":"Part ready to manufacturing",
                           "color":"good", "author_name":"Part ready to manufacture", "author_link":"#{CheesyCommon::Config.base_address}/parts/#{@part.id}",
                           "title":"Part name", "text":"#{@part.name.gsub! '&quot;', '"' }",
                           "fields":[{"title":"Material", "value":"#{@part.source_material}", "short":true},
                                     {"title":"Quantity", "value":"#{@part.quantity}", "short":true},
                                     {"title":"Priority", "value":"#{Part::PRIORITY_MAP[@part.priority]}", "short":true},
                                     {"title":"CNC Part?", "value":"#{@part.cnc_part == 1 ? "Yes" : "No"}", "short":true},
                                     {"title":"3D Print Part?", "value":"#{@part.print_part == 1 ? "Yes" : "No"}", "short":true},
                                     {"title":"Drawing Link", "value":"#{@part.drawing_link}", "short":true},
                                     {"title":"Gcode Link", "value":"#{@part.gcode_link}", "short":true},
                                     {"title":"Notes", "value":"#{@part.notes}", "short":false}]}])
        end
      end

      redirect params[:referrer] || "/parts/#{params[:id]}" unless !params[:redirect].nil? && params[:redirect]
    end

    get "/parts/:id/delete" do
      require_permission(@user.can_edit?)

      @part = Part[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      @referrer = request.referrer
      erb :part_delete
    end

    post "/parts/:id/delete" do
      require_permission(@user.can_edit?)

      @part = Part[params[:id]]
      project_id = @part.project_id
      halt(400, "Invalid part.") if @part.nil?
      halt(400, "Can't delete assembly with existing children.") unless @part.child_parts.empty?
      @part.delete
      params[:referrer] = nil if params[:referrer] =~ /\/parts\/#{params[:id]}$/
      redirect params[:referrer] || "/projects/#{project_id}"
    end

    # Subteam pages
    # Check that it is a valid subteam   
    before "/subteams/:name*" do
      @subteam = Subteam[params[:name]]
      halt(400, "Invalid subteam \"#{params[:name]}\"") if @subteam.nil?
    end

    # Subteam page (with tasks)
    get "/subteams/:subteam" do
      erb :subteam
    end    

    # Back to sub page after creating task
    post "/subteams/:subteam" do
      require_permission(@user.can_administer?)

      halt(400, "Missing task name.") if params[:name].nil?
      halt(400, "Missing deadline.") if params[:deadline].nil?

      task = Task.create(:name => params[:name], :project_id => params[:project_id], :deadline => params[:deadline], :sub_name => params[:subteam], :notes => params[:notes], :milestone_name => "")
      
      redirect "/subteams/#{task.sub_name}"
    end

    # Users
    get "/new_user" do
      require_permission(@user.can_administer?)
      @admin_new_user = true
      erb :new_user
    end

    get "/users" do
      require_permission(@user.can_administer?)
      erb :users
    end

    post "/users" do
      require_permission(@user.can_administer?)

      halt(400, "Missing email.") if params[:email].nil? || params[:email].empty?
      halt(400, "Invalid email.") unless params[:email] =~ /^\S+@\S+\.\S+$/
      halt(400, "User #{params[:email]} already exists.") if User[:email => params[:email]]
      halt(400, "Missing first name.") if params[:first_name].nil? || params[:first_name].empty?
      halt(400, "Missing last name.") if params[:last_name].nil? || params[:last_name].empty?
      halt(400, "Missing password.") if params[:password].nil? || params[:password].empty?
      halt(400, "Missing permission.") if params[:permission].nil? || params[:permission].empty?
      halt(400, "Invalid permission.") unless User::PERMISSION_MAP.include?(params[:permission])
      user = User.new(:email => params[:email], :first_name => params[:first_name],
                      :last_name => params[:last_name], :permission => params[:permission],
                      :enabled => (params[:enabled] == "on") ? 1 : 0)
      user.set_password(params[:password])
      user.save
      redirect "/users"
    end

    get "/users/:id/edit" do
      require_permission(@user.can_administer?)

      @user_edit = User[params[:id]]
      halt(400, "Invalid user.") if @user_edit.nil?
      erb :user_edit
    end

    post "/users/:id/edit" do
      require_permission(@user.can_administer?)

      @user_edit = User[params[:id]]
      halt(400, "Invalid user.") if @user_edit.nil?
      @user_edit.email = params[:email] if params[:email]
      @user_edit.first_name = params[:first_name] if params[:first_name]
      @user_edit.last_name = params[:last_name] if params[:last_name]
      @user_edit.set_password(params[:password]) if params[:password] && !params[:password].empty?
      @user_edit.permission = params[:permission] if params[:permission]
      old_enabled = @user_edit.enabled
      @user_edit.enabled = (params[:enabled] == "on") ? 1 : 0
      if @user_edit.enabled == 1 && old_enabled == 0
        email_body = <<-EOS.dedent
          Hello #{@user_edit.first_name},

          Your account on Cheesy Parts has been approved.
          You can log into the system at #{URL}.

          Cheers,

          The Cheesy Parts Robot
        EOS
        send_email(@user_edit.email, "Account approved", email_body)
      end
      @user_edit.save
      redirect "/users"
    end

    get "/users/:id/delete" do
      require_permission(@user.can_administer?)

      @user_delete = User[params[:id]]
      halt(400, "Invalid user.") if @user_delete.nil?
      erb :user_delete
    end

    post "/users/:id/delete" do
      require_permission(@user.can_administer?)

      @user_delete = User[params[:id]]
      halt(400, "Invalid user.") if @user_delete.nil?
      @user_delete.delete
      redirect "/users"
    end

    get "/change_password" do
      erb :change_password
    end

    post "/change_password" do
      halt(400, "Missing password.") if params[:password].nil? || params[:password].empty?
      halt(400, "Invalid old password.") unless User.authenticate(@user.email, params[:old_password])
      @user.set_password(params[:password])
      @user.save
      redirect "/"
    end

    get "/register" do
      @admin_new_user = false
      erb :new_user
    end

    post "/register" do
      halt(400, "Missing email.") if params[:email].nil? || params[:email].empty?
      halt(400, "Invalid email.") unless params[:email] =~ /^\S+@\S+\.\S+$/
      halt(400, "User #{params[:email]} already exists.") if User[:email => params[:email]]
      halt(400, "Missing first name.") if params[:first_name].nil? || params[:first_name].empty?
      halt(400, "Missing last name.") if params[:last_name].nil? || params[:last_name].empty?
      halt(400, "Missing password.") if params[:password].nil? || params[:password].empty?
      user = User.new(:email => params[:email], :first_name => params[:first_name],
                      :last_name => params[:last_name], :permission => "readonly",
                      :enabled => 0)
      user.set_password(params[:password])
      user.save
      email_body = <<-EOS.dedent
        Hello,

        This is a notification that #{user.first_name} #{user.last_name} has created an account on Cheesy
        Parts and it is disabled pending approval.
        Please visit the user control panel at #{URL}/users to take action.

        Cheers,

        The Cheesy Parts Robot
      EOS
      send_email(CheesyCommon::Config.gmail_user, "Approval needed for #{user.email}", email_body)
      erb :register_confirmation
    end

    # Orders
    get "/orders" do
      erb :orders_project_list
    end

    get "/projects/:id/orders/open" do
      @no_vendor_order_items = OrderItem.where(:order_id => nil, :project_id => params[:id])
      @vendor_orders = Order.filter(:status => "open").where(:project_id => params[:id]).order(:vendor_name, :ordered_at)
      @show_new_item_form = params[:new_item] == "true"
      erb :open_orders
    end

    get "/projects/:id/orders/ordered" do
      @vendor_orders = Order.filter(:status => "ordered").where(:project_id => params[:id]).
          order(:vendor_name, :ordered_at)
      erb :completed_orders
    end

    get "/projects/:id/orders/complete" do
      @vendor_orders = Order.filter(:status => "received").where(:project_id => params[:id]).
          order(:vendor_name, :ordered_at)
      erb :completed_orders
    end

    get "/projects/:id/orders/all" do
      @vendor_orders = Order.where(:project_id => params[:id]).order(:vendor_name, :ordered_at)
      if params[:filter]
        key, value = params[:filter].split(":")
        @vendor_orders = @vendor_orders.filter(key.to_sym => value)
      end
      erb :completed_orders
    end

    get "/projects/:id/orders/stats" do
      @orders = Order.filter(:status => "open").invert.where(:project_id => params[:id]).all
      @orders_by_vendor = @orders.inject({}) do |map, order|
        map[order.vendor_name] ||= []
        map[order.vendor_name] << order
        map
      end

      @orders_by_purchaser = @orders.inject({}) do |map, order|
        map[order.paid_for_by] ||= {}
        map[order.paid_for_by][:reimbursed] ||= 0
        map[order.paid_for_by][:outstanding] ||= 0
        if order.reimbursed == 1
          map[order.paid_for_by][:reimbursed] += order.total_cost
        else
          map[order.paid_for_by][:outstanding] += order.total_cost
        end
        map
      end

      erb :order_stats
    end

    post "/projects/:id/order_items" do
      require_permission(@user.can_edit?)
      halt(400, "Need to say who is requesting the order.") if params[:requested_by].nil? || params[:requested_by].empty?
      halt(400, "Link is missing.") if params[:link].nil? || params[:link].empty? 
      halt(400, "Need reason for request.") if params[:reason].nil? || params[:reason].empty?

      # Match vendor to an existing open order or create it if there isn't one.
      if params[:vendor].nil? || params[:vendor].empty?
        order_id = nil
      else
        order = Order.where(:project_id => @project.id, :vendor_name => params[:vendor],
                            :status => "open").first
        if order.nil?
          order = Order.create(:project => @project, :vendor_name => params[:vendor], :status => "open")
        end
        order_id = order.id
      end

      OrderItem.create(:project => @project, :order_id => order_id, :quantity => params[:quantity].to_i,
                       :part_number => params[:part_number], :description => params[:description],
                       :unit_cost => params[:unit_cost].gsub(/\$/, "").to_f, :requested_by => params[:requested_by], :link => params[:link], :reason => params[:reason])

      if CheesyCommon::Config.enable_slack_integrations
        $slack_client.chat_postMessage(:token => CheesyCommon::Config.slack_api_token, :channel => CheesyCommon::Config.slack_orders_room, :text => "Item added to order list!",
  				     :as_user => true, :attachments => [{"fallback":"#{params[:quantity]} of #{params[:part_number]} added to #{params[:vendor]} order list",
  								       "color":"danger", "author_name":"#{params[:vendor]} Order Status", 
                                       "author_link":"#{CheesyCommon::Config.base_address}/projects/#{@project.id}/orders/#{order_id}",
                                       "title":"Item", "text":"#{params[:description]}",
                                       "fields":[
                                                 {"title":"Reason", "value":"#{params[:reason]} (requested by #{params[:requested_by]})", "short":false},
                                                 {"title":"Quantity", "value":"#{params[:quantity]}", "short":true},
                                                 {"title":"Unit cost", "value":"#{('$' + ('%.2f' % (params[:unit_cost].gsub(/\$/, '').to_f).to_s))}", "short":true}]}])
      end
      redirect "/projects/#{@project.id}/orders/open"
    end

    get "/projects/:project_id/order_items/:id/editable" do
      require_permission(@user.can_edit?)

      @item = OrderItem[params[:id]]
      halt(400, "Invalid order item.") if @item.nil?
      erb :edit_order_item
    end

    post "/projects/:project_id/order_items/edit" do
      require_permission(@user.can_edit?)

      @item = OrderItem[params[:order_item_id]]
      halt(400, "Invalid order item.") if @item.nil?

      # Handle a vendor change.
      order_id = @item.order.id rescue nil
      old_vendor = @item.order.vendor_name rescue ""
      new_vendor = params[:vendor]
      unless old_vendor == new_vendor
        order = Order.where(:project_id => @project.id, :vendor_name => params[:vendor],
                            :status => "open").first
        if order.nil?
          order = Order.create(:project => @project, :vendor_name => params[:vendor], :status => "open")
        end
        order_id = order.id
      end

      @item.update(:order_id => order_id, :quantity => params[:quantity].to_i,
                   :part_number => params[:part_number], :description => params[:description],
                   :unit_cost => params[:unit_cost].gsub(/\$/, ""), :requested_by => params[:requested_by], :link => params[:link], :reason => params[:reason])
      redirect params[:referrer]
    end

    get "/projects/:project_id/order_items/:id/delete" do
      require_permission(@user.can_edit?)

      @item = OrderItem[params[:id]]
      halt(400, "Invalid order item.") if @item.nil?
      @referrer = request.referrer
      erb :order_item_delete
    end

    post "/projects/:project_id/order_items/:id/delete" do
      require_permission(@user.can_edit?)

      @item = OrderItem[params[:id]]
      halt(400, "Invalid order item.") if @item.nil?
      @item.delete
      redirect params[:referrer]
    end

    get "/projects/:id/orders/:order_id" do
      @order = Order[params[:order_id]]
      halt(400, "Invalid order.") if @order.nil?
      erb :order
    end

    post "/projects/:id/orders/:order_id/edit" do
      require_permission(@user.can_edit?)

      @order = Order[params[:order_id]]
      halt(400, "Invalid order.") if @order.nil?

      old_order_status = @order.status
      new_order_status = params[:status]

      @order.update(:status => params[:status], :ordered_at => params[:ordered_at],
                    :paid_for_by => params[:paid_for_by], :tax_cost => params[:tax_cost].gsub(/\$/, ""),
                    :shipping_cost => params[:shipping_cost].gsub(/\$/, ""), :notes => params[:notes],
                    :reimbursed => params[:reimbursed] ? 1 : 0)

      if CheesyCommon::Config.enable_slack_integrations
        unless old_order_status == new_order_status
          if params[:status].include?"ordered"
            $slack_client.chat_postMessage(:token => CheesyCommon::Config.slack_api_token, :channel => CheesyCommon::Config.slack_orders_room, :text => "Order placed!",
      				     :as_user => true, :attachments => [{"fallback":"Order from #{@order.vendor_name} has been placed",
      								       "color":"warning", "author_name":"#{@order.vendor_name} Order Status", "author_link":"#{CheesyCommon::Config.base_address}/projects/#{@project.id}/orders/#{@order.id}",
      								       "title":"#{@order.vendor_name} order has been placed", "text":"Order placed by #{params[:paid_for_by]} on #{params[:ordered_at]}",
                             "fields":[{"title":"Total cost", "value":"#{('$' + ('%.2f' % @order.total_cost))}", "short":true},
                                       {"title":"Order status", "value":"#{params[:status]}", "short":true}]}])
          elsif params[:status].include?"received"
            $slack_client.chat_postMessage(:token => CheesyCommon::Config.slack_api_token, :channel => CheesyCommon::Config.slack_orders_room, :text => "Order received!",
      				     :as_user => true, :attachments => [{"fallback":"Order from #{@order.vendor_name} has been received",
      								       "color":"good", "author_name":"#{@order.vendor_name} Order Status", "author_link":"#{CheesyCommon::Config.base_address}/projects/#{@project.id}/orders/#{@order.id}",
      								       "title":"#{@order.vendor_name} order has been received", "text":"Order placed by #{params[:paid_for_by]} on #{params[:ordered_at]}",
                                           "fields":[{"title":"Total cost", "value":"#{('$' + ('%.2f' % @order.total_cost))}", "short":true},
                                       {"title":"Order status", "value":"#{params[:status]}", "short":true}]}])
          end
        end
      end

      redirect "/projects/#{@project.id}/orders/#{@order.id}"
    end

    get "/projects/:id/orders/:order_id/delete" do
      require_permission(@user.can_edit?)

      @order = Order[params[:order_id]]
      halt(400, "Invalid order.") if @order.nil?
      halt(400, "Can't delete a non-empty order.") unless @order.order_items.empty?
      erb :order_delete
    end

    post "/projects/:id/orders/:order_id/delete" do
      require_permission(@user.can_edit?)

      @order = Order[params[:order_id]]
      halt(400, "Invalid order.") if @order.nil?
      halt(400, "Can't delete a non-empty order.") unless @order.order_items.empty?
      @order.delete
      redirect "/orders"
    end
  end
end
