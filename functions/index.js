const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

exports.sendSosNotification = functions.firestore
    .document("sos_broadcasts/{alertId}")
    .onCreate(async (snap) => {
      const data = snap.data();

      const tokensSnap = await admin.firestore()
          .collection("user_tokens").get();

      if (tokensSnap.empty) return null;

      const tokens = [];
      tokensSnap.forEach((doc) => {
        const token = doc.data().token;
        if (token && doc.data().userId !== data.userId) {
          tokens.push(token);
        }
      });

      if (tokens.length === 0) return null;

      const message = {
        notification: {
          title: `🚨 SOS Alert — ${data.category}`,
          body: `${data.userName}: ${data.message}`,
        },
        data: {
          alertId: data.alertId || "",
          userId: data.userId || "",
          latitude: String(data.latitude || ""),
          longitude: String(data.longitude || ""),
          category: data.category || "",
        },
        tokens: tokens,
      };

      try {
        const response = await admin.messaging().sendEachForMulticast(message);
        console.log(`Sent to ${response.successCount} devices`);
      } catch (e) {
        console.error("FCM error:", e);
      }

      return null;
    });
