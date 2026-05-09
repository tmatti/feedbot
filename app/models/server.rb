class Server < ApplicationRecord
  has_many :subscriptions, dependent: :destroy

  validates :discord_id, presence: true, uniqueness: true
  validates :name, presence: true
  validates :timezone, presence: true

  def self.upsert_from_discord!(guild_id:, name:)
    find_or_create_by!(discord_id: guild_id) do |s|
      s.name = name
    end.tap { |s| s.update!(name: name) }
  end
end
