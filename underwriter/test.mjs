// Checks SEP-53 verification against keys generated here (no network).
import crypto from "node:crypto"
process.env.POOL ??= "0xA801A7529C76414c811d954DdDD05Ceb63F75D8C"
process.env.UNDERWRITER_PRIVATE_KEY ??= "0x" + "11".repeat(32)
process.env.PORT = "0"
const { verifyStellarMessage, stellarAddressFromRaw } = await import("./server.mjs")

const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519")
const raw = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url")
const g = stellarAddressFromRaw(raw)
const message = "LCRD credit on Arc\nArc wallet: 0x0000000000000000000000000000000000000001\nStellar wallet: " + g + "\nIssued: " + new Date().toISOString()
const digest = crypto.createHash("sha256").update(Buffer.concat([Buffer.from("Stellar Signed Message:\n"), Buffer.from(message)])).digest()
const sig = crypto.sign(null, digest, privateKey).toString("base64")
const ok = verifyStellarMessage(g, message, sig)
const tampered = verifyStellarMessage(g, message + " ", sig)
console.log(g, { valid: ok, tamperedRejected: !tampered })
process.exit(ok && !tampered ? 0 : 1)
