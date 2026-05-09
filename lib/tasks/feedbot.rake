namespace :feedbot do
  desc "Register slash commands with Discord"
  task register_commands: :environment do
    commands = [
      {
        name: "feed",
        description: "Manage RSS/Atom feed subscriptions",
        default_member_permissions: "16",  # MANAGE_CHANNELS = 1 << 4
        options: [
          {
            type: 1,  # SUB_COMMAND
            name: "add",
            description: "Subscribe a channel to an RSS/Atom feed",
            options: [
              { type: 3, name: "url",      description: "Feed URL",                  required: true },
              { type: 7, name: "channel",  description: "Channel to post entries to", required: true },
              {
                type: 3, name: "mode", description: "Delivery mode", required: true,
                choices: [
                  { name: "realtime", value: "realtime" },
                  { name: "digest",   value: "digest" }
                ]
              },
              {
                type: 3, name: "schedule", description: "Digest schedule (required for digest mode)", required: false,
                choices: [
                  { name: "hourly",     value: "hourly" },
                  { name: "every_6h",   value: "every_6h" },
                  { name: "every_12h",  value: "every_12h" },
                  { name: "daily",      value: "daily" },
                  { name: "weekly",     value: "weekly" }
                ]
              },
              { type: 3, name: "at", description: "Time for daily/weekly digest (HH:MM, default 09:00)", required: false }
            ]
          },
          {
            type: 1,  # SUB_COMMAND
            name: "list",
            description: "List feed subscriptions for this server"
          },
          {
            type: 1,  # SUB_COMMAND
            name: "remove",
            description: "Remove a feed subscription",
            options: [
              { type: 3, name: "id", description: "Subscription to remove", required: true, autocomplete: true }
            ]
          },
          {
            type: 1,  # SUB_COMMAND
            name: "edit",
            description: "Edit an existing subscription",
            options: [
              { type: 3, name: "id",       description: "Subscription to edit",      required: true, autocomplete: true },
              { type: 7, name: "channel",  description: "New channel",               required: false },
              {
                type: 3, name: "mode", description: "New delivery mode", required: false,
                choices: [
                  { name: "realtime", value: "realtime" },
                  { name: "digest",   value: "digest" }
                ]
              },
              {
                type: 3, name: "schedule", description: "New schedule", required: false,
                choices: [
                  { name: "hourly",     value: "hourly" },
                  { name: "every_6h",   value: "every_6h" },
                  { name: "every_12h",  value: "every_12h" },
                  { name: "daily",      value: "daily" },
                  { name: "weekly",     value: "weekly" }
                ]
              },
              { type: 3, name: "at", description: "New time for daily/weekly (HH:MM)", required: false }
            ]
          },
          {
            type: 2,  # SUB_COMMAND_GROUP
            name: "config",
            description: "Server configuration",
            options: [
              {
                type: 1,  # SUB_COMMAND
                name: "timezone",
                description: "Set the server timezone for digest scheduling",
                options: [
                  { type: 3, name: "tz", description: "IANA timezone (e.g. America/New_York)", required: true }
                ]
              }
            ]
          }
        ]
      }
    ]

    client = Feedbot::Discord::RestClient.new
    result = client.put_global_commands(commands)
    puts "Registered #{result.length} command(s)."
  end
end
