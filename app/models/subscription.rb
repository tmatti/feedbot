class Subscription < ApplicationRecord
  belongs_to :server
  belongs_to :feed
  has_many :deliveries, dependent: :destroy

  validates :discord_channel_id, presence: true
  validates :created_by_discord_user_id, presence: true
  validates :mode, inclusion: { in: %w[realtime digest] }
  validates :status, inclusion: { in: %w[active disabled] }
  validates :schedule_kind,
    inclusion: { in: %w[hourly every_6h every_12h daily weekly] },
    allow_nil: true
  validate :schedule_required_for_digest
  validate :schedule_time_format

  scope :active, -> { where(status: "active") }
  scope :realtime, -> { where(mode: "realtime") }
  scope :digest, -> { where(mode: "digest") }
  scope :due_digests, -> { active.digest.where("next_run_at <= ?", Time.current) }

  CRON_MAP = {
    "hourly"     => "0 * * * *",
    "every_6h"   => "0 */6 * * *",
    "every_12h"  => "0 */12 * * *"
  }.freeze

  def derived_cron
    return nil unless mode == "digest" && schedule_kind.present?

    base =
      if CRON_MAP.key?(schedule_kind)
        CRON_MAP[schedule_kind]
      else
        time = schedule_time.presence || "09:00"
        hh, mm = time.split(":").map(&:to_i)
        day = schedule_kind == "weekly" ? "1" : "*"
        "#{mm} #{hh} * * #{day}"
      end
    "#{base} #{iana_timezone}"
  end

  def compute_next_run_at!
    cron_str = derived_cron
    return unless cron_str

    update!(
      schedule_cron: cron_str,
      next_run_at: Fugit.parse_cron(cron_str).next_time.to_t
    )
  end

  private

  # Fugit needs an IANA zone name in the cron string; resolve ActiveSupport
  # aliases like "Eastern Time (US & Canada)" to "America/New_York".
  def iana_timezone
    ActiveSupport::TimeZone[server.timezone]&.tzinfo&.name || server.timezone
  end

  def schedule_required_for_digest
    return unless mode == "digest"
    errors.add(:schedule_kind, "is required for digest mode") if schedule_kind.blank?
  end

  def schedule_time_format
    return if schedule_time.blank?
    errors.add(:schedule_time, "must be HH:MM") unless schedule_time.match?(/\A([01]?\d|2[0-3]):[0-5]\d\z/)
  end
end
