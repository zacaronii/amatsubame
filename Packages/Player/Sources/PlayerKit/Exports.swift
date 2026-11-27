// The engine protocol and its types (`PlayerEngine`, `PlayerTrack`, `BufferWait`…) live in their own
// package so the AetherEngine bridge can use them without MPVKit; everything that imports PlayerKit
// sees them as before.
@_exported import PlayerEngine
