import SwiftUI

struct ActivityLogView: View {
    @Bindable var model: AppModel

    var body: some View {
        Table(model.activityLog) {
            TableColumn("Time") { entry in
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
            }
            TableColumn("Category") { entry in
                Text(entry.category.rawValue)
            }
            TableColumn("Severity") { entry in
                Text(entry.severity.rawValue)
            }
            TableColumn("Conversation") { entry in
                Text(entry.conversationID ?? "Global")
            }
            TableColumn("Message") { entry in
                Text(entry.message)
                    .lineLimit(2)
            }
        }
        .task {
            await model.refreshActivityLog()
        }
        .navigationTitle("Activity Log")
        .padding()
    }
}
