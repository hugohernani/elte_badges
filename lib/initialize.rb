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

    tl = ExternalConfig.first_or_new(:config_type => 'twitter_for_login', :value => "px3qdHgbU2AK1e7OlRAkm6pJk",
      :shared_secret => "l7fbgRhidTanhdz8Hkx8U6OqvlsvghFgKlZPOMTZGh5CORqrY2")
    tl.save


    $domain = Domain.first_or_new(:host => "eltebadge.herokuapp.com", :name => "Elte Badges")
    $domain.save
    elte_domain = Domain.first_or_new(:host => "canvas.elte.hu", :name => "ELTE")
    elte_domain.save

    $org = Organization.first_or_new(:host => "eltebadge.herokuapp.com", :settings => {
        'name' => "Elte Award",
        'description' => "Elte Award to evaluate students",
        'twitter_login' => true,
        'url' => 'https://eltebadge.herokuapp.com',
        'image' => 'https://www.elte.hu/graphics/elte.ico',
        'email' => 'abonyita@gmail.com'
    })
    $org.save

    elte_org = Organization.first_or_new(:host => "canvas.elte.hu", :settings => {
        'name' => "Elte Award",
        'description' => "Elte Award to evaluate students",
        'twitter_login' => true,
        'url' => 'https://canvas.elte.hu',
        'image' => 'https://www.elte.hu/graphics/elte.ico',
        'email' => 'canvas@c2.hu'
    })
    elte_org.save


  end

  def external_configuration

    # settings = $org.settings
    # settings['oss_oauth'] = true
    # $org.settings = settings
    # $org.save

    ec1 = ExternalConfig.first_or_new(:config_type => 'canvas_oauth', :organization_id => $org.id)
    ec1.domain = $domain.name
    ec1.app_name = "Elte Badges"
    ec1.value = 10000000000003
    ec1.shared_secret = "mDNYgHiXtGdVrCJTJ3QZ0GPJA9KBz8m2Xcq06x92iclzsZOTpYf57CyJASAX9y3O"
    ec1.save

  end

end
