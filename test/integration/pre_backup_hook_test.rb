require "test_helper"

class PreBackupHookTest < ActiveSupport::TestCase
  test "pre-backup hook covers every production database file" do
    hook = File.read(Rails.root.join("hooks/pre-backup"))
    config = Rails.application.config_for(:database, env: "production")

    db_files = config.values.map { |c| File.basename(c[:database]) }
    assert db_files.any?, "expected production databases in config/database.yml"

    loop_line = hook[/^for db in (.+);/, 1]
    assert loop_line, "expected a `for db in ...` loop in hooks/pre-backup"
    hook_names = loop_line.split

    db_files.each do |file|
      assert_includes hook_names, File.basename(file, ".sqlite3"),
        "hooks/pre-backup does not back up #{file}"
    end
  end
end
