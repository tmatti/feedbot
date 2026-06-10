class Server < ApplicationRecord
  has_many :subscriptions, dependent: :destroy

  validates :discord_id, presence: true, uniqueness: true
  validates :name, presence: true
  validates :timezone, presence: true
end
