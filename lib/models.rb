require 'dm-core'
require 'dm-migrations'
require 'dm-types'
require 'sinatra/base'

# require(File.expand_path("../initialize", __FILE__))
# require 'initialize'

class Domain
  include DataMapper::Resource
  property :id, Serial
  property :host, String, :index => true
  property :name, String
end

class OrgStats
  include DataMapper::Resource
  property :id, Serial
  property :organization_id, String
  property :data, Json
  property :updated_at, DateTime

  def self.check(org)
    stats = OrgStats.first_or_new(:organization_id => org && org.id)
    if !stats.updated_at || stats.updated_at < (DateTime.now - 1.0)
      res = {}
      if org
        res['issuers'] = ExternalConfig.all(:organization_id => org.id).count
        res['badge_configs'] = BadgeConfig.all(:configured => true, :organization_id => org.id).count
        res['badge_placement_configs'] = BadgePlacementConfig.all(BadgePlacementConfig.badge_config.organization_id => org.id).count
        res['badges'] = BadgeConfig.all(:organization_id => org.id).map{|c| c.settings && c.settings['awarded_count'] }.compact.reduce(:+)
        res['last_badge_at'] = BadgeConfig.all(:organization_id => org.id).map{|c| c.settings && c.settings['last_badge_at'] }.compact.max
        res['domains'] = Domain.count
        res['organizations'] = Organization.count
      else
        res['issuers'] = ExternalConfig.count
        res['badge_configs'] = BadgeConfig.all(:configured => true).count
        res['badge_placement_configs'] = BadgePlacementConfig.count
        res['badges'] = BadgeConfig.all.map{|c| c.settings && c.settings['awarded_count'] }.compact.reduce(:+)
        res['last_badge_at'] = BadgeConfig.all.map{|c| c.settings && c.settings['last_badge_at'] }.compact.max
        res['domains'] = Domain.count
        res['organizations'] = Organization.count
      end
      stats.data = res
      stats.updated_at = DateTime.now
      stats.save
    end
    stats.data
  end
end

class Organization
  include DataMapper::Resource
  property :id, Serial
  property :host, String, :index => true
  property :old_host, String
  property :settings, Json

  def as_json
    host_with_port = self.host
    image = (settings && settings['image']) || "/organizations/default.png"
    if !image.match(/:\/\//)
      image = "#{BadgeHelper.protocol}://" + host_with_port + image
    end
    settings = self.settings || BadgeHelper.issuer
    {
      'name' => settings['name'],
      'url' => settings['url'],
      'description' => settings['description'],
      'image' => image,
      'email' => settings['email'],
      'revocationList' => "#{BadgeHelper.protocol}://#{host_with_port}/api/v1/organizations/#{self.id || 'default'}/revocations.json"
    }
  end

  def approved?
    self.settings && self.settings['approved']
  end

  def oss_config
    ExternalConfig.all(:organization_id => self.id, :config_type => 'canvas_oss_oauth')[0]
  end

  def lti_configs
    ExternalConfig.all(:organization_id => self.id, :config_type => 'lti')
  end

  def default?
    settings['default'] == true
  end

  def to_json
    as_json.to_json
  end

  def org_id
    "#{self.id}-#{self.settings['name'].downcase.gsub(/[^\w]+/, '-')[0, 30]}"
  end

  def self.default
    Organization.all.detect{|o| o.default? }
#     issuer = BadgeHelper.issuer
#     issuer_host = issuer['url'].split(/\/\//)[-1]
#     org = Organization.first(:host => issuer_host)
  end

  def editor_code
    return self.settings['editor_code'] if self.settings && self.settings['editor_code']
    raise "need id" unless self.id
    self.settings ||= {}
    self.settings['editor_code'] = self.id.to_s + "_" + Digest::MD5.hexdigest(Time.now.to_i.to_s + self.id.to_s + "editor" + rand(999).to_s)
    self.save
    self.settings['editor_code']
  end

  def user_code
    return self.settings['user_code'] if self.settings && self.settings['user_code']
    raise "need id" unless self.id
    self.settings ||= {}
    self.settings['user_code'] = self.id.to_s + "_" + Digest::MD5.hexdigest(Time.now.to_i.to_s + self.id.to_s + "editor" + rand(999).to_s)
    self.save
    self.settings['user_code']
  end

  def cleanup
    id = self.id
    self.destroy
    ExternalConfig.all(:organization_id => id).destroy
    BadgeConfig.all(:organization_id => id).destroy
    BadgePlacementConfig.all(:organization_id => id).destroy
  end

  def self.process(config, params)
    org = (config.organization_id && config.organization) || Organization.new
    if config.organization_editor? || !org.id
      org.settings ||= {}
      org.settings['name'] = params['name'] if params['name']
      org.settings['url'] = params['url'] if params['url']
      org.settings['description'] = params['description'] if params['description']
      org.settings['image'] = params['image'] if params['image']
      org.settings['email'] = params['email'] if params['email']
      org.settings['editor_config_ids'] ||= []
      org.settings['editor_config_ids'] << config.id
      org.settings['editor_config_ids'].uniq!
      if !org.id
        name = params['subdirectory'] || (org.settings['name'] || "organization").gsub(/[^\w]+/, '_')
        name = "organization" if name.length < 2
        numbered_name = name
        host_pre = Organization.default.host
        index = 0
        found_org = Organization.first(:host => host_pre + "/_" + numbered_name)
        while found_org
          index += 1
          numbered_name = name + index.to_s
          found_org = Organization.first(:host => host_pre + "/_" + numbered_name)
        end
        org.host = host_pre + "/_" + numbered_name
      end
      org.save
      org.editor_code
      org.user_code
      if params['oss']
        oss_config = org.oss_config
        oss_config ||= ExternalConfig.new(:organization_id => org.id, :config_type => 'canvas_oss_oauth')
        oss_config.value = params['developer_key'] if params['developer_key']
        oss_config.shared_secret = params['developer_secret'] if params['developer_secret']
        oss_config.save
      else
        oss_config = org.oss_config
        oss_config.destroy if oss_config
      end

      config.organization_id = org.id
      config.save!
    else
      false
    end
  end
end

class ExternalConfig
  include DataMapper::Resource
  property :id, Serial
  property :config_type, String
  property :domain, String
  property :app_name, String
  property :organization_id, Integer
  property :value, String
  property :shared_secret, String, :length => 256

  def confirmation
    hash = Digest::MD5.hexdigest(self.value + self.shared_secret)
  end

  def organization
    org = self.organization_id && Organization.first(:id => self.organization_id)
    org ||= Organization.default
    org
  end

  def organization_editor?
    org = self.organization_id && Organization.first(:id => self.organization_id)
    if org && org.settings
      (org.settings['editor_config_ids'] || []).include?(self.id)
    else
      false
    end
  end

  def disconnect_from_organization
    org = self.organization_id && Organization.first(:id => self.organization_id)
    if org
      org.settings['editor_config_ids'] ||= []
      org.settings['editor_config_ids'] = org.settings['editor_config_ids'] - [self.id]
      org.save
    end
    self.organization_id = nil
    res = self.save
    if ExternalConfig.all(:config_type => 'lti', :organization_id => org.id).count == 0 && BadgeConfig.all(:organization_id => org.id).count == 0
      org.cleanup
    end
  end

  def connect_to_organization(connect_code)
    id, code = connect_code.split(/_/, 2)
    org = Organization.first(:id => id)
    if org && org.editor_code == connect_code
      self.organization_id = org.id
      self.save
      org.settings['editor_config_ids'] ||= []
      org.settings['editor_config_ids'] << self.id
      org.save
    elsif org && org.user_code == connect_code
      self.organization_id = org.id
      self.save
    else
      false
    end
  end

  def self.generate(name)
    adaptdomain = AdaptDomain.new

    adaptdomain.external_configuration()

    conf = ExternalConfig.first_or_new(:config_type => 'lti', :app_name => name)
    conf.value ||= Digest::MD5.hexdigest(Time.now.to_i.to_s + rand.to_s).to_s
    conf.shared_secret ||= Digest::MD5.hexdigest(Time.now.to_i.to_s + rand.to_s + conf.value)
    conf.save
    conf

  end
end

class UserConfig
  # NOTE: Right now the code assumes if a UserConfig exists then there is an access token attached.
  include DataMapper::Resource
  property :id, Serial
  property :user_id, String
  property :access_token, String, :length => 512
  property :domain_id, Integer
  property :name, String, :length => 256
  property :email, String, :length => 512
  property :image, String, :length => 512
  property :global_user_id, String, :length => 256
  belongs_to :domain

  def host
    self.domain && self.domain.host
  end

  def profile_url
    if host
      "#{BadgeHelper.protocol}://" + host + "/users/" + self.user_id
    else
      "http://www.instructure.com"
    end
  end

  def check_badge_status(badge_placement_config, params, name, email)
    email ||= self.email
    scores_json = CanvasAPI.api_call("/api/v1/courses/#{badge_placement_config.course_id}?include[]=total_scores", self)
    modules_json = CanvasAPI.api_call("/api/v1/courses/#{badge_placement_config.course_id}/modules?student_id=#{self.user_id}", self, true) if badge_placement_config.modules_required?
    modules_json ||= []
    outcomes_json = CanvasAPI.api_call("/api/v1/courses/#{badge_placement_config.course_id}/outcome_rollups?include[]=outcomes&user_ids[]=#{self.user_id}", self, true) if badge_placement_config.outcomes_required?
    outcomes_json ||= {'linked' => {'outcomes' => []}, 'rollups' => []}
    completed_module_ids = modules_json.select{|m| m['completed_at'] }.map{|m| m['id'] }.compact
    rollup = outcomes_json['rollups'].detect{|r| r['links']['user'].to_s == self.user_id.to_s }
    rollup ||= outcomes_json['rollups'][0]
    rollup ||= {'scores' => []}
    scores = {}
    rollup['scores'].each do |score|
      scores[score['links']['outcome'].to_i] = score['score']
    end
    completed_outcome_ids = outcomes_json['linked']['outcomes'].select{|oc| (scores[oc['id'].to_i] || 0) >= oc['mastery_points'] }.map{|oc| oc['id'].to_i }.compact
    unless scores_json
      return "<h3>Error getting data from Canvas</h3>"
    end

    student = scores_json['enrollments'].detect{|e|  e['role'].downcase == 'studentenrollment' }
    student['computed_final_score'] ||= 0 if student

    if student
      if badge_placement_config.requirements_met?(student['computed_final_score'], completed_module_ids, completed_outcome_ids)
        params['credits_earned'] = badge_placement_config.credits_earned(student['computed_final_score'], completed_module_ids, completed_outcome_ids)
        if !email
          raise "You need to set an email address in Canvas before you can earn any badges."
        end
        badge = Badge.complete(params, badge_placement_config, name, email)
      elsif !badge
        badge = Badge.generate_badge({'user_id' => self.user_id}, badge_placement_config, name, email)
        badge.save
      end
    end
    return {
      :completed_module_ids => completed_module_ids,
      :completed_outcome_ids => completed_outcome_ids,
      :badge_config => badge_placement_config.badge_config,
      :badge_placement_config => badge_placement_config,
      :user_config => self,
      :badge => badge,
      :student => student
    }
  end
end

class BadgeConfigOwner
  include DataMapper::Resource
  property :id, Serial
  property :user_config_id, Integer
  property :badge_config_id, Integer
  property :badge_placement_config_id, Integer
  belongs_to :badge_config
  belongs_to :user_config
  belongs_to :badge_placement_config
end

class BadgeConfig
  include DataMapper::Resource
  property :id, Serial
  property :course_id, String # deprecated
  property :placement_id, String # deprecated
  property :teacher_user_config_id, Integer # deprecated
  property :nonce, String
  property :external_config_id, Integer # TODO: how is this used?
  property :organization_id, Integer
  property :domain_id, Integer # deprecated
  property :settings, Json # partially deprecated
  property :root_id, Integer # deprecated
  property :reference_code, String # deprecated
  property :reuse_code, String, :index => true
  property :public, Boolean
  property :uncool, Boolean
  property :configured, Boolean, :index => true
  property :updated_at, DateTime

  before :save, :generate_nonce
  belongs_to :external_config
  belongs_to :organization
  has n, :badge_placement_configs

  def as_json(host_with_port)
    settings = self.settings || {}
    image = settings['badge_url'] || "/badges/default.png"
    if settings['badge_url'].match(/^data:/)
      image = "/badges/from_config/#{self.id}/#{self.nonce}/badge.png"
    end
    image = "#{BadgeHelper.protocol}://" + host_with_port + image if image.match(/^\//)
    {
      :name => settings['badge_name'],
      :description => settings['badge_description'],
      :image => image,
      :criteria => "#{BadgeHelper.protocol}://#{host_with_port}/badges/criteria/#{self.id}/#{self.nonce}",
      :issuer => "#{BadgeHelper.protocol}://#{host_with_port}/api/v1/organizations/#{self.org_id}.json",
      :alignment => [], # TODO
      :tags => [] # TODO
    }
  end

  def self.uncool(id, uncool=true)
    bc = BadgeConfig.first(:id => id)
    if bc
      bc.uncool = uncool ? true : nil
      bc.save
    end
    bc.uncool
  end

  def to_json(host_with_port)
    as_json(host_with_port).to_json
  end

  def self.generate_badge_placement_configs
    BadgeConfig.all.each{|bc| bc.generate_badge_placement_config }
  end

  def generate_badge_placement_config
    if self.placement_id
      bc = BadgePlacementConfig.first_or_new(:placement_id => self.placement_id, :domain_id => self.domain_id)
      bc.course_id ||= self.course_id
      bc.teacher_user_config_id ||= self.teacher_user_config_id
      bc.external_config_id ||= self.external_config_id
      bc.organization_id ||= self.organization_id
      bc.domain_id ||= self.domain_id
      bc.updated_at = DateTime.now
      bc.set_badge_config(self)
      bc.save
      bc
    end
  end

  def org_id
    if self.organization && self.organization.settings
      "#{self.organization_id}-#{self.organization.settings['name'].downcase.gsub(/[^\w]+/, '-')[0, 30]}"
    else
      "default"
    end
  end

  def generate_nonce
    self.configured = self.configured?
    self.nonce ||= Digest::MD5.hexdigest(Time.now.to_i.to_s + rand.to_s)
    self.reuse_code ||= Digest::MD5.hexdigest(Time.now.to_i.to_s + rand.to_s)
  end

  def approve_to_pending?
    settings && (settings['manual_approval'] || settings['require_evidence'])
  end

  def update_counts
    self.settings ||= {}
    self.settings['awarded_count'] = Badge.all(:badge_config_id => self.id, :state => 'awarded').count
    last_badge = Badge.all(:badge_config_id => self.id, :state => 'awarded', :order => [:issued.desc]).first
    self.settings['last_badge_at'] = last_badge && last_badge.issued.iso8601
    self.save
  end

  def configured?
    !!(settings && settings['badge_url'])
  end
end

class BadgePlacementConfig
  include DataMapper::Resource
  property :id, Serial
  property :badge_config_id, Integer, :index => true
  property :course_id, String
  property :placement_id, String
  property :teacher_user_config_id, Integer
  property :author_user_config_id, Integer
  property :nonce, String # deprecated
  property :external_config_id, Integer # deprecated
  property :organization_id, Integer
  property :domain_id, Integer
  property :settings, Json # partially deprecated
  property :root_id, Integer # deprecated
  property :reference_code, String # deprecated
  property :public, Boolean #deprecated
  property :public_course, Boolean, :index => true
  property :updated_at, DateTime

  belongs_to :badge_config
  belongs_to :external_config
  belongs_to :organization
  belongs_to :domain

  def merged_settings
    settings = (self.badge_config && self.badge_config.settings) || {}
    settings.merge(self.settings || {})
  end

  def set_badge_config(badge_config)
    self.badge_config_id = badge_config.id
    self.settings ||= {}
    badge_settings = badge_config.settings || {}
    placement_settings = self.settings
    if badge_settings['min_percent'] != nil && placement_settings['min_percent'] == nil
      placement_settings['manual_approval'] = badge_settings['manual_approval']
      placement_settings['require_evidence'] = badge_settings['require_evidence']
      placement_settings['credit_based'] = badge_settings['credit_based']
      placement_settings['required_credits'] = badge_settings['requird_credits'].to_f.round(1)
      placement_settings['min_percent'] = badge_settings['min_percent'].to_f
      placement_settings['hours'] = badge_settings['hours'].to_f.round(1)
      placement_settings['hours'] = nil if placement_settings['hours'] == 0
      placement_settings['credits_for_final_score'] = badge_settings['credits_for_final_score'].to_f.round(1)
      placement_settings['modules'] = badge_settings['modules']
      placement_settings['outcomes'] = badge_settings['outcomes']
      placement_settings['total_credits'] = badge_settings['total_credits']

      self.settings = placement_settings
    end
    first_placement = badge_config.badge_placement_configs.first
    self.settings['prior_resource_link_id'] = first_placement.placement_id if first_placement

    self.save
    Badge.all(:badge_config_id => badge_config.id, :badge_placement_config_id => nil).update(:badge_placement_config_id => self.id)
    Badge.all(:badge_config_id => badge_config.id, :course_id => nil).update(:course_id => self.course_id)
  end

  def check_for_awardees
    teacher_config = self.teacher_user_config_id && UserConfig.first(:id => self.teacher_user_config_id)
    if teacher_config
      # get the paginated list of students
      # for each student, check if they already have a badge awarded
      # if not, check on award status
    end
  end

  def check_for_public_state
    return false unless self.domain
    host = "https://" + self.domain.host
    api = Canvas::API.new(:host => host, :token => "")
    begin
      json = api.get("/api/v1/courses/#{self.course_id}")
      self.public_course = !!(json && json['id'].to_s == self.course_id)
    rescue Canvas::ApiError => e
      self.public_course = false
    rescue Timeout::Error => e
      false
    end
  end

  def load_from_old_config(user_config, old_config=nil)
    self.settings ||= {}
    return nil if !self.settings['prior_resource_link_id'] || self.settings['already_loaded_from_old_config']
    old_config ||= BadgePlacementConfig.first(:placement_id => self.settings['prior_resource_link_id'], :domain_id => self.domain_id)
    old_config ||= BadgePlacementConfig.first(:placement_id => self.settings['prior_resource_link_id'], :badge_config_id => self.badge_config_id)
    if old_config
      # load config settings from previous badge config
      existing_settings = self.settings
      self.settings = old_config.settings

      # set to pending unless
      # able to get new module ids and map them correctly for module-configured badges
      self.settings['pending'] = true if old_config.modules_or_outcomes_required?
      self.settings['course_url'] = existing_settings['course_url'] if existing_settings

      api_user = UserConfig.first(:id => self.teacher_user_config_id) || user_config
      if api_user && old_config.modules_or_outcomes_required?
        # make an API call to get the module ids and try to map from old to new
        # map ids for module names and also credits_for values
        all_found = true
        if old_config.modules_required?
          new_modules = []
          modules_json = CanvasAPI.api_call("/api/v1/courses/#{self.course_id}/modules", api_user, true) || []
          old_config.settings['modules'].each do |id, str, credits|
            new_module = modules_json.detect{|m| m['name'] == str}
            if new_module
              new_modules << [new_module['id'].to_s.to_i, str, credits]
            else
              all_found = false
            end
          end
          self.settings['modules'] = new_modules
        end
        if old_config.outcomes_required?
          new_outcomes = []
          outcomes_json = CanvasAPI.api_call("/api/v1/courses/#{self.course_id}/outcome_group_links", api_user, true) || []
          old_config.settings['outcomes'].each do |id, str, credits|
            new_outcome = outcomes_json.detect{|oc| oc['outcome']['id'] == id || oc['outcome']['title'] == str}
            if new_outcome
              new_outcomes << [new_outcome['outcome']['id'].to_s.to_i, str, credits]
            else
              all_found = false
            end
          end
          self.settings['outcomes'] = new_outcomes
        end
        self.settings['pending'] = !all_found
      end
      self.settings['already_loaded_from_old_config'] = true
      self.save
    end
  end

  def approve_to_pending?
    settings && (settings['manual_approval'] || settings['require_evidence'])
  end

  def update_counts
    self.settings ||= {}
    self.settings['awarded_count'] = Badge.all(:badge_placement_config_id => self.id, :state => 'awarded').count
    last_badge = Badge.all(:badge_placement_config_id => self.id, :state => 'awarded', :order => [:issued.desc]).first
    self.settings['last_badge_at'] = last_badge && last_badge.issued.iso8601
    self.save
    self.badge_config.update_counts
  end

  def pending?
    settings && settings['pending']
  end

  def needs_old_config_load?
    settings && !settings['min_percent'] && settings['prior_resource_link_id']
  end

  def award_only?
    settings && settings['award_only']
  end

  def configured?
    !!(self.settings && self.badge_config && self.badge_config.settings && self.badge_config.settings['badge_url'] && self.settings['min_percent'] && !self.pending? && !self.award_only?)
  end

  def modules_or_outcomes_required?
    modules_required? || outcomes_required?
  end

  def outcomes_required?
    settings && settings['outcomes']
  end

  def modules_required?
    settings && settings['modules']
  end

  def evidence_required?
    settings && settings['require_evidence']
  end

  def credit_based?
    !!(settings && settings['credit_based'] && settings['required_credits'])
  end

  def required_modules
    (settings && settings['modules']) || []
  end

  def required_outcomes
    (settings && settings['outcomes']) || []
  end

  def required_module_ids
    required_modules.map(&:first).map(&:to_i)
  end

  def required_outcome_ids
    required_outcomes.map(&:first).map(&:to_i)
  end

  def required_modules_completed?(completed_module_ids)
    incomplete_module_ids = self.required_module_ids - completed_module_ids
    incomplete_module_ids.length == 0
  end

  def required_outcomes_completed?(completed_outcome_ids)
    incomplete_outcome_ids = self.required_outcome_ids - completed_outcome_ids
    incomplete_outcome_ids.length == 0
  end

  def required_score_met?(percent)
    settings && percent >= settings['min_percent']
  end

  def credits_earned(percent, completed_module_ids, completed_outcome_ids)
    credits = required_score_met?(percent) ? settings['credits_for_final_score'].to_f : 0
    (settings['modules'] || []).each do |id, name, credit|
      if completed_module_ids.include?(id.to_i)
        credits += (credit || 0)
      end
    end
    (settings['outcomes'] || []).each do |id, name, credit|
      if completed_outcome_ids.include?(id.to_i)
        credits += (credit || 0)
      end
    end
    credits
  end

  def requirements_met?(percent, completed_module_ids, completed_outcome_ids)
    if credit_based?
      credits = credits_earned(percent, completed_module_ids, completed_outcome_ids)
      credits > 0 && credits > settings['required_credits'].to_f
    else
      required_modules_completed?(completed_module_ids) &&
        required_outcomes_completed?(completed_outcome_ids) &&
        required_score_met?(percent)
    end
  end
end

class Badge
  include DataMapper::Resource
  property :id, Serial
  property :placement_id, String
  property :user_id, String, :index => [:user_badge, :earned_badge]
  property :domain_id, Integer, :index => :earned_badge
  property :badge_url, Text
  property :nonce, String
  property :badge_config_id, Integer, :index => :user_badge
  property :badge_placement_config_id, Integer
  property :name, String, :length => 256
  property :user_full_name, String, :length => 256
  property :description, Text
  property :credits_earned, Integer
  property :recipient, String, :length => 512
  property :salt, String, :length => 512
  property :issued, DateTime
  property :email, String
  property :evidence_url, String, :length => 4096
  property :manual_approval, Boolean
  property :public, Boolean
  property :state, String, :index => [:earned_badge, :awarded_counter]
  property :course_id, String, :index => :earned_badge
  property :global_user_id, String, :length => 256
  property :issuer_name, String
  property :issuer_image_url, String
  property :issuer_org, String
  property :issuer_url, String
  property :issuer_email, String

  belongs_to :badge_config
  belongs_to :badge_placement_config
  before :save, :generate_defaults
  after :save, :check_for_notify_on_award

  def open_badge_json(host_with_port)
    image = self.badge_url
    if image && self.badge_config
      bc = self.badge_config
      if image != bc.settings['badge_url']
        # We must correct the image path before sending it to backpack
        self.badge_url = bc.settings["badge_url"]
        self.save
        image = self.badge_url
      end
      if image.match(/^data:/)
        image = "/badges/from_badge/#{self.id}/#{self.nonce}/badge.png"
        image = "#{BadgeHelper.protocol}://" + host_with_port + image
      end
      if image.match(/^\//)
        image = "#{BadgeHelper.protocol}://#{host_with_port}" + image
      end
    end

    {
      :uid => self.id.to_s,
      :recipient => {
        :identity => self.recipient,
        :type => "email",
        :hashed => true,
        :salt => self.salt
      },
      :badge => "#{BadgeHelper.protocol}://#{host_with_port}/api/v1/badges/summary/#{self.badge_config_id}/#{self.config_nonce}.json",
      :verify => {
        :type => "hosted",
        :url => "#{BadgeHelper.protocol}://#{host_with_port}/api/v1/badges/data/#{self.badge_config_id}/#{self.user_id}/#{self.nonce}.json"
      },
      :issuedOn => (self.issued && self.issued.strftime("%Y-%m-%d")),
      :image => image,
      :evidence => (self.evidence_url || "#{BadgeHelper.protocol}://#{host_with_port}/badges/criteria/#{self.badge_config_id}/#{self.config_nonce}?user=#{self.nonce}")
    }
  end

  def generate_defaults
    self.salt ||= Time.now.to_i.to_s
    self.nonce ||= Digest::MD5.hexdigest(self.salt + rand.to_s)
    self.issued ||= DateTime.now if self.awarded?

    sha = Digest::SHA256.hexdigest(self.email + self.salt)
    self.recipient = "sha256$#{sha}"

    self.badge_placement_config ||= BadgePlacementConfig.first(:placement_id => self.placement_id, :domain_id => self.domain_id)
    self.badge_config ||= self.badge_placement_config && self.badge_placement_config.badge_config
    user_config = UserConfig.first(:user_id => self.user_id, :domain_id => self.domain_id)
    self.global_user_id = user_config.global_user_id if user_config
    true
  end

  def check_for_notify_on_award
    # check if state just changed to awarded or completed, notify via email if that's the case
  end

  def user_name
    conf = UserConfig.first(:user_id => self.user_id, :domain_id => self.domain_id)
    (conf && conf.name) || self.user_full_name
  end

  def config_nonce
    self.badge_placement_config ||= BadgePlacementConfig.first(:placement_id => self.placement_id, :domain_id => self.domain_id)
    self.badge_config ||= self.badge_placement_config && self.badge_placement_config.badge_config
    self.badge_config && self.badge_config.nonce
  end

  def needing_evaluation?
    !awarded? && !pending?
  end

  def awarded?
    self.state == 'awarded'
  end

  def pending?
    self.state == 'pending'
  end

  def revoke
    self.state = 'revoked'
    save
    self.badge_placement_config && self.badge_placement_config.update_counts
  end

  def award
    self.state = 'awarded'
    save
    self.badge_placement_config && self.badge_placement_config.update_counts
  end

  def self.generate_badge(params, badge_placement_config, name, email)
    settings = badge_placement_config.merged_settings || {}
    badge = self.first_or_new(:user_id => params['user_id'], :badge_config_id => badge_placement_config.badge_config_id)
    badge.badge_placement_config = badge_placement_config
    badge.placement_id = badge_placement_config.placement_id
    badge.domain_id = badge_placement_config.domain_id
    badge.course_id = badge_placement_config.course_id

    if settings && settings['org'] && settings['org'].is_a?(Hash)
      badge.issuer_image_url = settings['org']['image']
      badge.issuer_org = settings['org']['name']
      badge.issuer_url = settings['org']['url']
      badge.issuer_email = settings['org']['email']
    end

    badge.issuer_name = BadgeHelper.issuer['name']
    badge.badge_config = badge_placement_config.badge_config
    badge.name = settings['badge_name']
    badge.email = email
    badge.state ||= 'unissued'
    badge.credits_earned = params['credits_earned'].to_i
    badge.user_full_name = name || params['user_name']
    badge.description = settings['badge_description']
    badge.badge_url = settings['badge_url']
    badge
  end

  def self.manually_award(params, badge_placement_config, name, email)
    badge = generate_badge(params, badge_placement_config, name, email)
    badge.manual_approval = true unless badge.pending?
    badge.state = 'awarded'
    badge.issued = DateTime.now
    badge.save
    badge_placement_config.update_counts
    badge
  end

  def self.complete(params, badge_placement_config, name, email)
    badge = generate_badge(params, badge_placement_config, name, email)
    badge.state = nil if badge.state == 'unissued'
    badge.state ||= badge_placement_config.approve_to_pending? ? 'pending' : 'awarded'
    badge.save
    badge_placement_config.update_counts
    badge
  end
end
