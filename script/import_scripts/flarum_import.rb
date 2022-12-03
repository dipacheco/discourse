# frozen_string_literal: true

require "mysql2"
require 'time'
require 'date'

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::FLARUM < ImportScripts::Base
  #SET THE APPROPRIATE VALUES FOR YOUR MYSQL CONNECTION
  FLARUM_HOST ||= ENV['FLARUM_HOST'] || "localhost"
  FLARUM_DB ||= ENV['FLARUM_DB'] || "flarum_db"
  BATCH_SIZE ||= 1000
  FLARUM_USER ||= ENV['FLARUM_USER'] || "root"
  FLARUM_PW ||= ENV['FLARUM_PW'] || ""
  AVATARS_DIR ||= ENV['AVATARS_DIR'] || '/shared/import/data/avatars/'

  def initialize
    super

    @client = Mysql2::Client.new(
      host: FLARUM_HOST,
      username: FLARUM_USER,
      password: FLARUM_PW,
      database: FLARUM_DB
    )
  end

  def execute

    import_users
    import_categories
    import_posts
    create_permalinks

  end

  def import_users
    puts '', "creating users"
    total_count = mysql_query("SELECT count(*) count FROM users;").first['count']

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(
        "SELECT id, username, email, password, avatar_url, joined_at, last_seen_at, suspended_until
         FROM users
         LIMIT #{BATCH_SIZE}
         OFFSET #{offset};")

      break if results.size < 1

      next if all_records_exist? :users, results.map { |u| u["id"].to_i }

      create_users(results, total: total_count, offset: offset) do |user|
        { id: user['id'],
          email: user['email'],
          username: user['username'],
          name: user['username'],
          password_hash: user['password'],
          created_at: user['joined_at'],
          suspended_till: user['suspended_until'],
          last_seen_at: user['last_seen_at'],
          post_create_action: proc do |newuser|
            puts "", "post create action"
            if user['avatar_url'] && user['avatar_url'].length > 0
              photo_path = AVATARS_DIR + user['avatar_url']
              puts "#{photo_path} - user"
              if File.exist?(photo_path)
                begin
                  upload = create_upload(newuser.id, photo_path, File.basename(photo_path))
                  if upload && upload.persisted?
                    newuser.import_mode = false
                    newuser.create_user_avatar
                    newuser.import_mode = true
                    newuser.user_avatar.update(custom_upload_id: upload.id)
                    newuser.update(uploaded_avatar_id: upload.id)
                  else
                    puts "Error: Upload did not persist for #{photo_path}!"
                  end
                rescue SystemCallError => err
                  puts "Could not import avatar #{photo_path}: #{err.message}"
                end
              else
                puts "avatar file not found at #{photo_path}"
              end
            end
          end
        }
      end
    end
  end

  def import_categories
    puts "", "importing top level categories..."

    categories = mysql_query("
                              SELECT id, name, description, position
                              FROM tags
                              ORDER BY position ASC
                            ").to_a

    create_categories(categories) do |category|
      {
        id: category["id"],
        name: category["name"]
      }
    end

    puts "", "importing children categories..."

    children_categories = mysql_query("
                                       SELECT id, name, description, position
                                       FROM tags
                                       ORDER BY position
                                      ").to_a

    create_categories(children_categories) do |category|
      {
        id: "child##{category['id']}",
        name: category["name"],
        description: category["description"],
      }
    end
  end

  def import_posts
    puts "", "creating topics and posts"

    total_count = mysql_query("SELECT count(*) count from posts").first["count"]

    batches(BATCH_SIZE) do |offset|
      results = mysql_query("
        SELECT p.id id,
               d.id topic_id,
               d.title title,
               d.first_post_id first_post_id,
               p.user_id user_id,
               p.content raw,
               p.created_at created_at,
               t.tag_id category_id
        FROM posts p,
             discussions d,
             discussion_tag t
        WHERE p.discussion_id = d.id
          AND t.discussion_id = d.id
        ORDER BY p.created_at
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ").to_a

      break if results.size < 1
      next if all_records_exist? :posts, results.map { |m| m['id'].to_i }

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        mapped[:id] = m['id']
        mapped[:user_id] = user_id_from_imported_user_id(m['user_id']) || -1
        mapped[:raw] = process_FLARUM_post(m['raw'], m['id'])
        mapped[:created_at] = Time.zone.at(m['created_at'])

        if m['id'] == m['first_post_id']
          mapped[:category] = category_id_from_imported_category_id("child##{m['category_id']}")
          mapped[:title] = CGI.unescapeHTML(m['title'])
        else
          parent = topic_lookup_from_imported_post_id(m['first_post_id'])
          if parent
            mapped[:topic_id] = parent[:topic_id]
          else
            puts "Parent post #{m['first_post_id']} doesn't exist. Skipping #{m["id"]}: #{m["title"][0..40]}"
            skip = true
          end
        end

        skip ? nil : mapped
      end
    end
  end

  def create_permalinks
    puts '', 'Creating redirects...', ''

    # https://discuss.flarum.org/d/29620-flarum-slug-problem
    puts '', 'Posts...', ''
    Topic.find_each do |topic|
      pcf = topic.first_post.custom_fields
      if pcf && pcf["import_id"]
        id = pcf["import_id"]
        slug = Slug.for(topic.title)
        Permalink.create(url: "d/#{id}-#{slug}", topic_id: topic.id) rescue nil
        print '.'
      end
    end
    
    puts '', 'Categories...', ''
    Category.find_each do |cat|
      ccf = cat.custom_fields
      next unless id = ccf["import_id"]
      slug = cat['slug']
      Permalink.create(url: "d/#{id}-#{slug}", category_id: cat.id) rescue nil
      print '.'
    end
  end
  
  def process_FLARUM_post(raw, import_id)
    s = raw.dup

    s
  end

  def use_bbcode_to_md?
    true
  end
  
  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end
end

ImportScripts::FLARUM.new.perform
