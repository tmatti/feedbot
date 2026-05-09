class Delivery < ApplicationRecord
  belongs_to :subscription
  belongs_to :entry

  validates :subscription_id, uniqueness: { scope: :entry_id }
end
