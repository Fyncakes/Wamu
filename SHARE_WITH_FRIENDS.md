# Share Wamu with friends

## On your PC (one control)

```bash
./start_wamu.sh          # start server + public link
./stop_wamu.sh            # stop everything
./start_wamu.sh --apk     # also rebuild the APK
```

After start, open `dist/SHARE.txt` — it has the live links.

## Give friends the APK

File: **`dist/wamu-phone.apk`** (also served when the server is on).

Ways to install:
1. Send the APK file (WhatsApp / Drive / USB)
2. Or send the download URL printed by `./start_wamu.sh`  
   (`…/media-files/wamu-phone.apk`)

Android may ask to allow installs from unknown sources.

## Friends connect to your PC

1. You run `./start_wamu.sh` and keep the PC awake
2. Friend installs APK
3. Friend opens the **Connect** link you share (`…/connect`) **or** in the app: **You → Wamu server** and pastes the API URL
4. Login with any `+256…` number and OTP **`123456`**

Same Wi‑Fi as your PC? They can use `http://YOUR-LAN-IP:8000` instead of the public link.

## Notes

- OTP is still mock (`123456`) so friends can try without SMS cost
- Public Cloudflare URL can change when you restart — re-share after `./start_wamu.sh`
- For a fixed URL forever: `./infrastructure/setup_named_tunnel.sh`
