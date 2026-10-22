/// Google Cloud ONE-TIME setup knobs (see SYNC_PLAN.md §Setup).
///
/// Web OAuth client (owner-created once in Google Cloud Console).
const String kSyncWebClientId =
    '417596522828-7l9ir40omsbf2090l6gnppm8pu47o6dt.apps.googleusercontent.com';

/// Drive scope for the app-private backup folder.
const String kDriveAppdataScope = 'https://www.googleapis.com/auth/drive.appdata';

/// Pasted below in case the scope list grows.
const List<String> kDriveScopes = [kDriveAppdataScope];
