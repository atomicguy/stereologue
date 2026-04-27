//
//  UserDataErrorHandling.swift
//  Stereologue
//
//  View modifier for displaying UserDataService errors to users.
//

import SwiftUI

extension View {
    /// Displays an alert when UserDataService encounters an error.
    ///
    /// Apply this to views that use UserDataService to automatically
    /// show error alerts to users.
    ///
    /// Example:
    /// ```swift
    /// struct MyView: View {
    ///     @Environment(UserDataService.self) private var userDataService
    ///
    ///     var body: some View {
    ///         // ... your view content
    ///         .userDataErrorAlert()
    ///     }
    /// }
    /// ```
    func userDataErrorAlert() -> some View {
        modifier(UserDataErrorAlertModifier())
    }
}

private struct UserDataErrorAlertModifier: ViewModifier {
    @Environment(UserDataService.self) private var userDataService
    
    func body(content: Content) -> some View {
        content
            .alert(
                "Data Error",
                isPresented: .constant(userDataService.lastError != nil),
                presenting: userDataService.lastError
            ) { error in
                Button("OK") {
                    userDataService.clearLastError()
                }
            } message: { error in
                Text(error.localizedDescription)
            }
    }
}

#if DEBUG
#Preview {
    // Example of how to use the error alert
    struct ExampleView: View {
        @Environment(UserDataService.self) private var userDataService
        
        var body: some View {
            VStack {
                Text("Example View")
                
                Button("Toggle Favorite (Test)") {
                    userDataService.toggleFavorite(cardUUID: "test-uuid")
                }
            }
            .padding()
            .userDataErrorAlert()
        }
    }
    
    return ExampleView()
        .previewEnvironment()
}
#endif
