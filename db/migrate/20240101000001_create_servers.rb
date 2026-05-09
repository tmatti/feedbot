class CreateServers < ActiveRecord::Migration[8.1]
  def change
    create_table :servers do |t|
      t.bigint  :discord_id, null: false
      t.string  :name, null: false
      t.string  :timezone, null: false, default: "UTC"
      t.timestamps
    end
    add_index :servers, :discord_id, unique: true
  end
end
