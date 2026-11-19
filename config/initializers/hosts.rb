Rails.application.config.hosts << "datagb.sfei.org"
Rails.application.config.hosts << "www.example.com" if Rails.env.test?
