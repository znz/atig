#! /opt/local/bin/ruby -w
# -*- mode:ruby; coding:utf-8 -*-

require 'fileutils'
require 'atig/util'
require "net/irc"
require "ostruct"
require "time"
require 'yaml'
require 'atig/url_escape'
require 'atig/fake_twitter'
require 'atig/twitter'
require 'atig/oauth'
require 'atig/db/db'
require 'atig/channel_gateway'
require 'atig/option'

begin
  require 'continuation'
rescue LoadError => e
end

module Atig
  class Gateway < Net::IRC::Server::Session
    include Util

    class << self
      def self.class_writer(*ids)
        ids.each do|id|
          module_eval <<END
def #{id}=(arg)
  @@#{id} = arg
end
END
        end
      end

      class_writer :commands, :agents, :ifilters, :ofilters, :channels
    end

    def initialize(*args); super end

    def post(*args)
      super
    end

    def update_status(ret, target, msg='')
      @db.transaction do|db|
        db.statuses.add(:source => :me, :status => ret, :user => ret.user )
      end

      msg = "(#{msg})" unless msg.empty?
      self[target].notify "Status updated #{msg}"
    end

    def channel(name)
      channel = ChannelGateway.new(:session => self,
                                   :name    => name,
                                   :filters => @ifilters,
                                   :prefix  => @prefix,
                                   :nick    => @nick,
                                   :opts    => @opts)
      @channels[name] = channel
      channel
    end

    def [](name)
      @channels[name]
    end

    def output_message(query)
      @ofilters.inject(query) {|x, f| f.call x }
    end

    def ctcp_action(*commands, &block)
      commands.each do |command|
        @ctcp_actions[command] = block
      end
    end

    protected
    def on_message(m)
      @on_message.call(m) if @on_message
    end

    def on_user(m)
      super
      @ctcp_actions = {}
      @channels     = {}
      load_config

      @real, @opts = Atig::Option.parse @real
      context = OpenStruct.new(:log=>@log, :opts=>@opts)

      oauth = OAuth.new(@real)
      unless oauth.verified? then
        channel = channel '#oauth'
        channel.join_me
        channel.notify "Please approve me at #{oauth.url}"
        callcc{|cc|
          @on_message = lambda{|m|
            if m.command.downcase == 'privmsg' then
              _, mesg = *m.params
              if oauth.verify(mesg.strip)
                channel.part_me "Verified"
                save_config
                cc.call
              end
            end
            return true
          }
          return
        }
      end

      log :debug, "initialize Twitter"
      @twitter = Twitter.new   @log, oauth.access
      @api     = Scheduler.new context, @twitter

      log :debug, "initialize filter"
      @ifilters = run_new @@ifilters, context
      @ofilters = run_new @@ofilters, context

      @api.delay(0) do|t|
        me  = t.post "account/update_profile"
        unless me then
          log :info, <<END
Failed to access API.
Please check Twitter Status <http://status.twitter.com/> and try again later.
END
          finish
        end

        post server_name, MODE, @nick, "+o"

        @db = Atig::Db::Db.new context, :me=>me, :size=> 100
        run_new @@commands, context, self, @api, @db
        run_new @@agents  , context, @api, @db
        run_new @@channels, context, self, @db

        @db.statuses.add :user => me, :source => :me, :status => me.status
      end
    end

    def run_new(klasses,*args)
      (klasses || []).map do|klass|
        if klass.respond_to?(:new)
          klass.new(*args)
        else
          klass
        end
      end
    end

    def save_config
      FileUtils.mkdir_p File.expand_path("~/.atig/")
      File.open(File.expand_path("~/.atig/oauth"),"w") {|io|
        YAML.dump(OAuth.dump,io)
      }
    end

    def load_config
      FileUtils.mkdir_p File.expand_path("~/.atig/")
      OAuth.load(YAML.load_file(File.expand_path("~/.atig/oauth"))) rescue nil
    end

    def on_privmsg(m)
      target, mesg = *m.params

      m.ctcps.each {|ctcp| on_ctcp(target, ctcp) } if m.ctcp?

      return if mesg.empty?
      return on_ctcp_action(target, mesg) if mesg.sub!(/\A +/, "")
      on_ctcp_action(target, "status #{mesg}")
    end

    def on_ctcp(target, mesg)
      type, mesg = mesg.split(" ", 2)
      method = "on_ctcp_#{type.downcase}".to_sym
      send(method, target, mesg) if respond_to? method, true
    end

    def on_ctcp_action(target, mesg)
      safe do
        command, *args = mesg.split(" ")
        if command
          command.downcase!
          @ctcp_actions.each do |define, f|
            if define === command
              f.call(target, mesg, Regexp.last_match || command, args)
            end
          end
        else
          log :info, "[tig.rb] CTCP ACTION COMMANDS:"
          @ctcp_actions.keys.each do |c|
            log :info, c
          end
        end
      end
    end

    def available_user_modes
      "o"
    end

    def available_channel_modes
      "mntiovah"
    end
  end
end
