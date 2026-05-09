class CreateSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :subscriptions do |t|
      t.references :server, null: false, foreign_key: true
      t.references :feed, null: false, foreign_key: true
      t.bigint  :discord_channel_id, null: false
      t.bigint  :created_by_discord_user_id, null: false
      t.string  :mode, null: false
      t.string  :schedule_kind
      t.string  :schedule_time
      t.string  :schedule_cron
      t.datetime :next_run_at
      t.string  :status, null: false, default: "active"
      t.timestamps
    end
    add_index :subscriptions, :next_run_at
    add_index :subscriptions, [ :server_id, :feed_id, :discord_channel_id ], unique: true
  end
end
