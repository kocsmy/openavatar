import Foundation

/// Cosine distance (1 − cosine similarity) between voice embeddings.
/// Mismatched dimensions — e.g. a legacy 25-dim spectral fingerprint against
/// a 256-dim neural one — are "infinitely far": they can never match, so old
/// profiles are simply grandfathered out of matching rather than corrupting
/// it. Used by the store's stray-voice sweep; live diarization happens inside
/// the backend's own clustering (see SpeakerDiarizer).
func voiceCosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    let denom = na.squareRoot() * nb.squareRoot()
    guard denom > 0 else { return .greatestFiniteMagnitude }
    return 1 - dot / denom
}
