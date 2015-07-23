require(File.expand_path("../canvabadges", __FILE__))
$stdout.sync = true

require(File.expand_path("../lib/initialize", __FILE__))
adaptdomain = AdaptDomain.new
adaptdomain.initial_configuration()
run Canvabadges
