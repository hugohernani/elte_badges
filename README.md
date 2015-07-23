Badges
---------------------------
This is an LTI-enabled service that allows you to award badges
(Mozilla Open Badges, specifically) to students in a course
based on their accomplishments in the course. Currently this
will only work with Canvas.

This instance was prepared to be used on the instance Canvas of the university ELTE. If you wanna know how to create your own you can go to the whitney repository at: https://github.com/whitmer/canvabadges

If you wanna see the Whitney Canvabadges presentations, go here: https://canvabadges.herokuapp.com.

Canvabadges now supports multiple badges per course, and has better
support for launching from multiple courses in the same session.

## Setup on CANVAS.ELTE.HU

## External authentication

Twitter and Canvas developer keys

## Twitter developer keys
First, it is needed to setup some developer keys on https://apps.twitter.com/
Go here and create a new app. The main informations are website (where you are hosting THIS canvabadges instance) and Callback URL.
Ex.

if your host is my_canvas_badge.herokuapp.com,
Website will have: https://my_canvas_badges.herokuapp.com and your Callback URL will have: https://my_canvas_badges.herokuapp.com/login_success

**Note**: this application will get 'login_success' to check oAuth keys from twitter. That is why you shoul use the path **login_success**.

After creating your app, go to **Keys and Access Tokens** and keep in my your "Consumer Key (API Key)" and "Consumer Secret (API Secret)". Those are used to authenticate THIS app with twitter.

## Canvas developer keys

As a **admin** go to http://canvas.elte.hu/developer_keys and create a **Developer key**. Fill the dialog, but keep in mind that on **Redirect URI** you should this path: *oauth_success*. So, if your host is my_canvas_badges.herokuapp.com, your Redirect URI will be: https://my_canvas_badges.herokuapp.com/oauth_success. After creating your developer key, copy and save your **ID** and **key**. Those are used to make the *OAuth Dance* with Canvas.

## Environment Variables

This ruby (Sinatra) app makes use of some Environment Variable. Two of them are **DATABASE_URL** (*Postgres*) and **SESSION_KEY** which is a key manually generate to be used on the session. You can do so with a simple in-line ruby code as the following which generate a random alphanumeric string:

```bash
[*('a'..'z'),*('0'..'9')].shuffle[0,8].join
```

Both of those variable are **required**, so it needs to be created and set.

## Configuration on "*lib/initialize.rb*"

On **lib** directory there is a file called **initialize_sample.rb**. On this file some changes needs to be made to adapt your information with this instance.
On **initial_configuration** method replace the following fields with the keys created on the steps above:

**TWITTER_CONSUMER_KEY**

**TWITTER_SECRET_KEY**

It is also needed to replace HOST_NAME with your HOST. It is not needed to use the protocol. But on HOST_URL you should use the protocol. You can also change other information as domain name, organzation name, description, image and email as you wish.

```ruby
def initial_configuration
  BadgeConfig.generate_badge_placement_configs
  FixupMigration.enlarge_columns

  tl = ExternalConfig.first_or_new(:config_type => 'twitter_for_login',
  :value => TWITTER_CONSUMER_KEY,
  :shared_secret => TWITTER_CONSUMER_KEY)
  tl.save

  $domain = Domain.first_or_new(:host => "HOST_NAME", :name => "Elte Award")
  $domain.save
  $org = Organization.first_or_new(:host => "HOST_NAME", :settings => {
      'name' => "Elte Award",
      'description' => "Elte Award to evaluate students",
      'twitter_login' => true,
      'url' => 'HOST_URL',
      'image' => 'https://www.elte.hu/graphics/elte.ico',
      'email' => 'canvas@c2.hu'
  })
  $org.save
end

```

On **external_configuration** method replace the following fields with the keys created on the steps above:

**ELTE_DEV_CONSUMER_KEY**

**ELTE_DEV_SECRET_KEY**

```ruby
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
```

Then change the file name from **initialize_sample.rb** to **initialize.rb**, or replace it if already exist.

After done with this configuration you can run your canvas badge application, go to your host and follow the instructions there to install it as a external_tool on you Canvas instance.

NOTE: Attempt to the .gitignore file. Maybe lib/initialize is by default to be ignored. Remove that you are making tests by updating to the server.
