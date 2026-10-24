/// Firebase settings for push notifications (FCM).
///
/// Fill these 4 values from Firebase console -> Project settings -> General ->
/// "Your apps" -> Android app (package name: com.ananta.ott).
/// Leave them empty to keep push notifications disabled (the app runs normally).
/// No google-services.json file is needed.
const String kFirebaseApiKey = 'AIzaSyADyGffwOiIegiVo-gQe5p_h3HXVfSi90A';          // "Web API Key" / current_key
const String kFirebaseAppId = '1:585456937879:android:474ace233c789681d0b2d2';           // e.g. 1:1234567890:android:abcdef123456
const String kFirebaseSenderId = '585456937879';        // "Project number"
const String kFirebaseProjectId = 'anantaott';       // e.g. ananta-ott

/// Every installed app subscribes to this topic. Send a notification to the
/// topic "all" from Firebase console -> Messaging to reach every phone.
const String kPushTopic = 'all';
