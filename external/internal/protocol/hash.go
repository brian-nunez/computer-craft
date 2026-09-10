package protocol

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
)

// SHA256Hex returns the lowercase hexadecimal SHA-256 digest of message.
// CraftNet renders every digest and MAC in lowercase hexadecimal on the wire.
func SHA256Hex(message []byte) string {
	digest := sha256.Sum256(message)
	return hex.EncodeToString(digest[:])
}

// HMACHex returns the lowercase hexadecimal HMAC-SHA-256 of message under key.
func HMACHex(key, message []byte) string {
	mac := hmac.New(sha256.New, key)
	mac.Write(message)
	return hex.EncodeToString(mac.Sum(nil))
}

// CheckModemFrameSize applies the raw-modem ceiling. A modem receiver discards
// larger frames before JSON decoding, so this runs before any parsing.
func CheckModemFrameSize(text string) error {
	if len(text) > ModemFrameBytes {
		return newError(CodeMessageTooLarge, "frame exceeds %d bytes", ModemFrameBytes)
	}
	return nil
}
