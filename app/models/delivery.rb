class Delivery < ApplicationRecord
  belongs_to :subscription
  belongs_to :entry

  # Uniqueness of (subscription_id, entry_id) is enforced by the database's
  # unique index; a model-level uniqueness validation would defeat
  # create_or_find_by! (RecordInvalid instead of the rescued RecordNotUnique).
end
