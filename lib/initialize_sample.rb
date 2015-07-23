require './canvabadges.rb'

$org = nil
$domain = nil

class AdaptDomain

  def organization
    $org
  end

  def domain
    $domain
  end

  def initial_configuration
    BadgeConfig.generate_badge_placement_configs
    FixupMigration.enlarge_columns

    tl = ExternalConfig.first_or_new(:config_type => 'twitter_for_login',
    :value => TWITTER_CONSUMER_KEY,
    :shared_secret => TWITTER_CONSUMER_KEY)
    tl.save

    # ex. of hostname: eltebadge.herokuapp.com
    $domain = Domain.first_or_new(:host => "HOSTNAME", :name => "Elte Award")
    $domain.save
    $org = Organization.first_or_new(:host => "HOSTNAME", :settings => {
        'name' => "Elte Award",
        'description' => "Elte Award to evaluate students",
        'twitter_login' => true,
        'url' => 'HOST_URL',
        'image' => 'https://www.elte.hu/graphics/elte.ico',
        'email' => 'canvas@c2.hu'
    })
    $org.save
  end

  def external_configuration

    settings = $org.settings
    settings['oss_oauth'] = true
    $org.settings = settings
    $org.save

    ec1 = ExternalConfig.first_or_new(:config_type => 'canvas_oauth', :organization_id => $org.id)
    ec1.domain = $domain.name
    ec1.app_name = "Elte Award"
    ec1.value = ELTE_DEV_CONSUMER_KEY
    ec1.shared_secret = "ELTE_DEV_SECRET_KEY"
    ec1.save

  end

end
