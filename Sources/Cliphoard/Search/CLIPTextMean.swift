/// The text tower's common direction — subtract it, or the query barely matters.
///
/// MEASURED, not assumed. OpenVision-Tiny's text space is extremely anisotropic: over 450
/// generic prompts (90 nouns x 5 templates) the mean pairwise cosine between UNRELATED
/// concepts is +0.9980, and the mean vector itself has norm 0.9990 — every embedding is
/// very nearly the same vector. "cat" and "invoice" sit 0.998 apart.
///
/// The consequence is not subtle. With raw cosine, every query returned the SAME images in
/// the same order: a few pictures happen to sit close to this common direction and win
/// everything, regardless of what was typed. That is textbook hubness, and it is why "cat"
/// appeared not to work while "a photo of a cat" appeared to work slightly better — the two
/// queries are 0.996 apart, so both were swamped, and templating merely nudged a residual
/// that carries ~2% of the magnitude and 100% of the meaning.
///
/// Subtracting this and renormalising takes the mean pairwise cosine from +0.9980 to
/// +0.0019 — from near-identical to near-orthogonal.
///
/// GENERIC BY CONSTRUCTION. Computed from a fixed vocabulary of ordinary nouns and neutral
/// templates, never from any user's clips: tuning it to a corpus would bake that corpus into
/// the model and make results depend on what someone happened to copy.
///
/// Compiled in rather than read from a file, deliberately. The whole feature was already
/// dark once because a 30-byte config.json was missing from the bundle; a constant cannot
/// go absent. Regenerate with tools/convert_openvision.py if the weights ever change — a
/// mean from different weights is worse than none.
enum CLIPTextMean {
    static let vector: [Float] = [
        -0.01035882, +0.07373437, -0.02613891, +0.00027735, +0.10296953, -0.04007994,
        +0.03892755, -0.02558480, +0.03585941, +0.01899787, -0.02145640, +0.01082565,
        +0.05595481, +0.05779995, +0.02398836, -0.02495233, +0.00313988, +0.04364499,
        +0.03255591, -0.11352871, +0.02225598, -0.00993204, +0.02212074, -0.10690856,
        -0.00696822, +0.02481867, -0.05053962, +0.01112776, +0.04413772, -0.07624874,
        -0.03601800, +0.11906394, +0.05135195, +0.03823643, -0.02159445, +0.01618690,
        +0.31150278, -0.03858684, +0.00653417, +0.02414863, +0.05735591, +0.02608448,
        +0.00048052, +0.04611555, -0.05464790, +0.03842547, +0.09021425, -0.06442023,
        +0.03869411, -0.18449245, -0.03485388, -0.31572059, -0.11676593, +0.02758918,
        -0.01088321, -0.06034189, +0.04228086, -0.30001482, -0.03567608, -0.01191356,
        +0.01151916, -0.00658293, -0.02555302, -0.01727918, +0.01277332, +0.00277106,
        +0.02972168, +0.04500901, -0.01849806, +0.13070546, -0.03626478, +0.00612181,
        -0.01553083, +0.00430789, -0.07727501, -0.06878091, +0.02858135, -0.18568638,
        -0.02085644, +0.05322573, +0.08015539, +0.01448202, -0.05025237, -0.01092565,
        -0.00479099, +0.02060176, +0.02533955, +0.02619005, +0.04212385, +0.00117230,
        +0.05620319, -0.02303165, +0.06573917, +0.01086860, -0.09899267, +0.01454654,
        -0.02629111, +0.05198995, +0.04755447, +0.00601555, +0.05357179, +0.07550848,
        -0.03823794, +0.06270503, +0.00338821, +0.00982981, -0.13494568, +0.02535898,
        -0.01914016, +0.06768188, +0.04821766, +0.00743872, +0.06868090, -0.03305886,
        -0.03469439, -0.03113894, +0.28779373, +0.01957370, -0.08620181, +0.06267277,
        -0.00396765, -0.01556061, +0.14987583, -0.08556508, -0.00836514, +0.00300530,
        -0.05668933, +0.02870619, -0.08408263, -0.04113535, +0.07709030, -0.01181371,
        -0.02315705, -0.04376960, -0.00516041, -0.02631917, -0.00867883, +0.01339250,
        -0.01661762, +0.04052616, +0.02528303, -0.05579052, +0.05674254, -0.00477249,
        +0.00914135, -0.07400792, -0.02924715, +0.03629414, -0.02828197, +0.00701507,
        +0.00365673, -0.00259864, +0.03138082, +0.03603195, -0.00336251, +0.01030028,
        +0.14069055, -0.00467149, -0.13348533, -0.11648675, +0.00291827, -0.01062238,
        -0.00783985, -0.03264116, -0.14048027, -0.04991360, -0.00009157, -0.03059082,
        +0.07054350, +0.01992614, +0.00407484, +0.08488053, +0.06462789, -0.05386123,
        +0.04771415, -0.00052895, +0.01947773, -0.00776335, +0.01854731, -0.02917044,
        -0.01114923, -0.05252204, -0.01498447, -0.01554634, +0.02513364, -0.00267487,
        -0.06635658, +0.02436977, +0.31146997, -0.02177290, +0.08885228, -0.00671016,
    ]
}
