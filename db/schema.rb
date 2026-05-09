# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2024_01_01_000005) do
  create_table "deliveries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "discord_message_id"
    t.integer "entry_id", null: false
    t.string "error"
    t.datetime "posted_at"
    t.boolean "skipped", default: false, null: false
    t.integer "subscription_id", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_id"], name: "index_deliveries_on_entry_id"
    t.index ["subscription_id", "entry_id"], name: "index_deliveries_on_subscription_id_and_entry_id", unique: true
    t.index ["subscription_id"], name: "index_deliveries_on_subscription_id"
  end

  create_table "entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "feed_id", null: false
    t.string "guid", null: false
    t.string "image_url"
    t.datetime "published_at"
    t.text "summary"
    t.string "title"
    t.string "url"
    t.index ["feed_id", "guid"], name: "index_entries_on_feed_id_and_guid", unique: true
    t.index ["feed_id"], name: "index_entries_on_feed_id"
    t.index ["published_at"], name: "index_entries_on_published_at"
  end

  create_table "feeds", force: :cascade do |t|
    t.string "canonical_url"
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "etag"
    t.string "last_error"
    t.string "last_modified"
    t.datetime "last_polled_at"
    t.datetime "next_poll_at"
    t.string "status", default: "active", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["next_poll_at"], name: "index_feeds_on_next_poll_at"
    t.index ["url"], name: "index_feeds_on_url", unique: true
  end

  create_table "servers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "discord_id", null: false
    t.string "name", null: false
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.index ["discord_id"], name: "index_servers_on_discord_id", unique: true
  end

  create_table "subscriptions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_discord_user_id", null: false
    t.bigint "discord_channel_id", null: false
    t.integer "feed_id", null: false
    t.string "mode", null: false
    t.datetime "next_run_at"
    t.string "schedule_cron"
    t.string "schedule_kind"
    t.string "schedule_time"
    t.integer "server_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["feed_id"], name: "index_subscriptions_on_feed_id"
    t.index ["next_run_at"], name: "index_subscriptions_on_next_run_at"
    t.index ["server_id", "feed_id", "discord_channel_id"], name: "idx_on_server_id_feed_id_discord_channel_id_29b6647252", unique: true
    t.index ["server_id"], name: "index_subscriptions_on_server_id"
  end

  add_foreign_key "deliveries", "entries"
  add_foreign_key "deliveries", "subscriptions"
  add_foreign_key "entries", "feeds"
  add_foreign_key "subscriptions", "feeds"
  add_foreign_key "subscriptions", "servers"
end
