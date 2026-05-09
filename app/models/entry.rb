class Entry < ApplicationRecord
  belongs_to :feed
  has_many :deliveries, dependent: :destroy

  validates :guid, presence: true, uniqueness: { scope: :feed_id }
  validates :feed_id, presence: true

  scope :undelivered_for, ->(subscription) {
    where.not(id: subscription.deliveries.select(:entry_id))
  }
end
