class CreateDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :deliveries do |t|
      t.references :subscription, null: false, foreign_key: true
      t.references :entry, null: false, foreign_key: true
      t.datetime :posted_at
      t.bigint   :discord_message_id
      t.boolean  :skipped, null: false, default: false
      t.string   :error
      t.timestamps
    end
    add_index :deliveries, [ :subscription_id, :entry_id ], unique: true
  end
end
