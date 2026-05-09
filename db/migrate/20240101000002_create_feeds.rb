class CreateFeeds < ActiveRecord::Migration[8.1]
  def change
    create_table :feeds do |t|
      t.string   :url, null: false
      t.string   :canonical_url
      t.string   :title
      t.string   :etag
      t.string   :last_modified
      t.datetime :last_polled_at
      t.datetime :next_poll_at
      t.integer  :consecutive_failures, null: false, default: 0
      t.string   :last_error
      t.string   :status, null: false, default: "active"
      t.timestamps
    end
    add_index :feeds, :url, unique: true
    add_index :feeds, :next_poll_at
  end
end
