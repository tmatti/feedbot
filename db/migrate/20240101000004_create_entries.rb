class CreateEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :entries do |t|
      t.references :feed, null: false, foreign_key: true
      t.string   :guid, null: false
      t.string   :url
      t.string   :title
      t.text     :summary
      t.string   :image_url
      t.datetime :published_at
      t.datetime :created_at, null: false
    end
    add_index :entries, :published_at
    add_index :entries, [ :feed_id, :guid ], unique: true
  end
end
