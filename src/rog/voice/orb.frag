#version 440
// ============================================================================
//  Hermes VoiceOrb — "Aurora glass" fragment shader.
//  A 3D-shaded glass sphere (analytic normals — no raymarch cost) holding a
//  domain-warped fbm nebula, fresnel/iridescent rim, dual speculars, and a
//  surrounding waveform halo ring. All motion derives from uTime (frozen by
//  QML while paused) and the live audio level.
//  Compile: /usr/lib64/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 \
//           -o orb.frag.qsb orb.frag
// ============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float uTime;    // seconds, monotonic; QML freezes it while paused
    float uLevel;   // smoothed audio RMS 0..1 (mic or TTS)
    float uEnv;     // energy envelope 0..1 (state baseline + level)
    float uSpin;    // interior swirl speed multiplier (state)
    float uBreath;  // breathing amplitude (state)
    float uGlow;    // halo strength (state)
    float uThink;   // 0..1 thinking (orbiting comet, fast sweep)
    float uErr;     // 0..1 error (red strobe)
    float uSpeak;   // 0..1 speaking (radiating light ripples)
    vec4  uPri;     // state palette
    vec4  uSec;
    vec4  uAcc;
};

// ---- value noise + fbm ------------------------------------------------------
float hash(vec3 p) {
    p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
float noise(vec3 x) {
    vec3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash(i + vec3(0, 0, 0)), hash(i + vec3(1, 0, 0)), f.x),
                   mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
               mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
                   mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fbm(vec3 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 4; i++) { s += a * noise(p); p = p * 2.07 + vec3(13.7); a *= 0.5; }
    return s;
}

void main() {
    vec2 uv = qt_TexCoord0 * 2.0 - 1.0;        // -1..1 quad space
    uv.y = -uv.y;
    float r = length(uv);
    float t = uTime;

    vec3 pri = uPri.rgb, sec = uSec.rgb, acc = uAcc.rgb;

    // error strobe (reddens core + halo)
    float errP = uErr * (0.5 + 0.5 * sin(t * 14.0));

    // breathing sphere radius; the mic/TTS level swells it slightly
    float Rb = 0.56 * (1.0 + uBreath * sin(t * 1.7) + 0.055 * uLevel + 0.10 * errP);

    // ======================= HALO (always computed — blends under sphere) ====
    float th = atan(uv.y, uv.x);
    float d  = max(r - Rb, 0.0);
    float fall = exp(-d * 6.0);
    float wisp = fbm(vec3(cos(th), sin(th), 0.4) * 1.8 + vec3(0.0, 0.0, t * 0.22));
    vec3 halo = mix(pri, sec, 0.5 + 0.5 * sin(t * 0.4 + th)) * fall
              * (0.10 + 0.30 * uEnv) * uGlow * (0.65 + 0.7 * wisp);

    // waveform ring — radius modulated by interfering harmonics, with a
    // travelling hotspot ("comet" — fast + bright while thinking)
    float wave = sin(th * 6.0 + t * 2.6) * sin(th * 11.0 - t * 1.9) * 0.5
               + sin(th * 17.0 + t * 3.4) * 0.22;
    float ringR = Rb * (1.30 + 0.06 * wave * (0.25 + 0.75 * uEnv) + 0.03 * uLevel);
    float rd = r - ringR;
    float ring = exp(-rd * rd * 3200.0) * (0.18 + 0.82 * uEnv);
    float sweep = 0.5 + 0.5 * cos(th - t * (1.3 + 2.2 * uThink));
    ring *= 0.30 + 0.70 * sweep;
    vec3 ringCol = mix(pri, acc, sweep) * ring * 1.7;

    vec3 outCol = halo + ringCol;
    outCol = mix(outCol, vec3(1.0, 0.22, 0.28), errP * 0.35 * fall);
    float outA = clamp(max(max(outCol.r, outCol.g), outCol.b), 0.0, 1.0) * 0.92;

    // ======================= SPHERE ==========================================
    vec3 col = outCol;
    float alpha = outA;
    if (r < Rb + 0.01) {
        vec2 p = uv / Rb;
        float pr2 = min(dot(p, p), 1.0);
        float z = sqrt(1.0 - pr2);
        vec3 n = vec3(p, z);

        // --- interior nebula: fbm on the slowly tumbling sphere, domain-warped
        float ca = cos(t * 0.25 * uSpin), sa = sin(t * 0.25 * uSpin);
        vec3 sp = vec3(n.x * ca - n.z * sa, n.y, n.x * sa + n.z * ca);   // spin Y
        float cb = cos(t * 0.11 * uSpin), sb = sin(t * 0.11 * uSpin);
        sp = vec3(sp.x, sp.y * cb - sp.z * sb, sp.y * sb + sp.z * cb);   // tumble X
        vec3 q = sp * 2.2;
        float w  = fbm(q + 0.65 * vec3(fbm(q + vec3(0.0, t * 0.16, 0.0))));
        float w2 = fbm(q * 1.9 - vec3(t * 0.12, 0.0, t * 0.07));

        vec3 core = mix(sec, pri, smoothstep(0.22, 0.78, w)) * 1.05;
        core += acc * pow(max(w2 - 0.32, 0.0) * 1.7, 2.0);              // filaments
        core *= 0.34 + 0.78 * z;                                        // depth → volume
        core *= 1.0 + 0.45 * uLevel;                                    // voice = light

        // speaking: light ripples radiating from the heart, synced to level
        float rip = uSpeak * (0.15 + 0.85 * uLevel)
                  * sin(18.0 * sqrt(pr2) - t * 7.5);
        core *= 1.0 + 0.30 * max(rip, 0.0);

        // thinking: a bright comet orbiting inside the glass
        if (uThink > 0.005) {
            vec2 cp = 0.55 * vec2(cos(t * 2.1), sin(t * 2.1) * 0.82);
            float cd2 = dot(p - cp, p - cp);
            vec2 cpt = 0.55 * vec2(cos(t * 2.1 - 0.45), sin((t * 2.1 - 0.45)) * 0.82);
            float td2 = dot(p - cpt, p - cpt);
            core += uThink * (acc * exp(-cd2 * 30.0) * 1.5      // head
                            + pri * exp(-td2 * 9.0) * 0.45);    // trailing glow
        }

        // --- glass shell: fresnel rim, angular iridescence, dual speculars
        float fres = pow(1.0 - z, 2.6);
        vec3 iri = mix(pri, acc, 0.5 + 0.5 * sin(th * 3.0 + t * 0.6));
        vec3 rim = mix(pri, iri, 0.65) * fres * (1.05 + 0.55 * uEnv);

        vec3 L1 = normalize(vec3(-0.55, 0.65, 0.52));
        vec3 L2 = normalize(vec3(0.45, -0.50, 0.45));
        float spec = pow(max(dot(n, L1), 0.0), 52.0) * 0.85
                   + pow(max(dot(n, L2), 0.0), 22.0) * 0.16;

        vec3 sph = core * 0.92 + rim + vec3(spec);
        sph = sph / (1.0 + 0.38 * sph);          // Reinhard-ish: tame highlight blowout
        sph = mix(sph, vec3(1.0, 0.22, 0.28), errP * 0.45);
        float sphA = 0.90 + 0.10 * fres;

        // anti-aliased sphere edge over the halo
        float aa = smoothstep(Rb + 0.008, Rb - 0.008, r);
        col = mix(outCol, sph, aa);
        alpha = mix(outA, sphA, aa);
    }

    fragColor = vec4(col * alpha, alpha) * qt_Opacity;   // premultiplied
}
