const jwt = require("jsonwebtoken");
const fs = require("fs");

const privateKey = fs.readFileSync("AuthKey_KJN58M35CZ.p8");

const token = jwt.sign(
  {},
  privateKey,
  {
    algorithm: "ES256",
    expiresIn: "180d",
    audience: "https://appleid.apple.com",
    issuer: "GL9U974DM2",      // your Team ID
    subject: "com.nagrom.roadtrip.auth",  // Services ID
    keyid: "KJN58M35CZ"             // Apple Key ID
  }
);

console.log(token);