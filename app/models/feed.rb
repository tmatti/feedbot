class Feed < ApplicationRecord
  has_many :subscriptions, dependent: :destroy
  has_many :entries, dependent: :destroy

  validates :url, presence: true, uniqueness: true
  validates :status, inclusion: { in: %w[active disabled] }

  scope :active, -> { where(status: "active") }
  scope :due_for_poll, -> { active.where("next_poll_at IS NULL OR next_poll_at <= ?", Time.current) }

  BACKOFF_MINUTES = [ 5, 15, 60, 240 ].freeze

  def note_failure!(error_message)
    failures = consecutive_failures + 1
    backoff = BACKOFF_MINUTES[[ failures - 1, BACKOFF_MINUTES.length - 1 ].min].minutes
    attrs = {
      consecutive_failures: failures,
      last_error: error_message,
      next_poll_at: Time.current + backoff
    }
    attrs[:status] = "disabled" if failures >= 20
    update!(attrs)
  end

  def note_success!(etag: nil, last_modified: nil, canonical_url: nil)
    update!(
      consecutive_failures: 0,
      last_error: nil,
      last_polled_at: Time.current,
      next_poll_at: 15.minutes.from_now,
      etag: etag || self.etag,
      last_modified: last_modified || self.last_modified,
      canonical_url: canonical_url || self.canonical_url
    )
  end
end
