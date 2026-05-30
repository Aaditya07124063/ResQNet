const functions = require("firebase-functions");
const admin = require("firebase-admin");

admin.initializeApp();

// Triggered when a new SOS is added to sos_broadcasts collection
exports.sendSosNotification = functions.firestore
    .document("sos_broadcasts/{alertId}")
    .onCreate(async (snap, context) => {
      const alert = snap.data();

      // Don't send if already sent
      if (alert.notificationSent) return null;

      const category = alert.category || "GENERAL";
      const userName = alert.userName || "Someone";
      const message = alert.message || "Emergency! Need help!";

      // Notification content
      const title = `🆘 ${category} EMERGENCY`;
      const body = `${userName}: ${message}`;

      // Get all user FCM tokens
      const tokensSnapshot = await admin
          .firestore()
          .collection("user_tokens")
          .get();

      if (tokensSnapshot.empty) {
        console.log("No users to notify");
        return null;
      }

      const tokens = tokensSnapshot.docs.map((doc) => doc.data().token);

      // Send to all devices
      const payload = {
        notification: {
          title: title,
          body: body,
          sound: "default",
        },
        data: {
          alertId: alert.alertId || "",
          category: category,
          userName: userName,
          message: message,
          latitude: String(alert.latitude || ""),
          longitude: String(alert.longitude || ""),
          click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
        android: {
          priority: "high",
          notification: {
            channelId: "resqnet_emergency",
            priority: "max",
            defaultVibrateTimings: true,
            defaultSound: true,
          },
        },
        apns: {
          payload: {
            aps: {
              sound: "default",
              badge: 1,
              contentAvailable: true,
            },
          },
        },
      };

      // Send in batches of 500
      const chunkSize = 500;
      for (let i = 0; i < tokens.length; i += chunkSize) {
        const chunk = tokens.slice(i, i + chunkSize);
        await admin.messaging().sendEachForMulticast({
          tokens: chunk,
          ...payload,
        });
      }

      // Mark as sent
      await snap.ref.update({notificationSent: true});

      console.log(`SOS notification sent to ${tokens.length} devices`);
      return null;
    });
