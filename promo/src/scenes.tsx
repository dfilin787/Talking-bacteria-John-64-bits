import React from "react";
import {
  AbsoluteFill,
  interpolate,
  useCurrentFrame,
  useVideoConfig,
  Easing,
} from "remotion";
import {
  Background,
  Badge,
  COLORS,
  GameScreen,
  GlowTitle,
  LogoIcon,
  Phone,
  Sub,
} from "./atoms";

const Center: React.FC<{ children: React.ReactNode; gap?: number }> = ({
  children,
  gap = 22,
}) => (
  <AbsoluteFill
    style={{
      justifyContent: "center",
      alignItems: "center",
      display: "flex",
      flexDirection: "column",
      gap,
    }}
  >
    {children}
  </AbsoluteFill>
);

export const SceneLogo: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = interpolate(frame, [0.1 * fps, 0.6 * fps], [0.6, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.spring({ damping: 13, stiffness: 150 }),
  });
  return (
    <AbsoluteFill>
      <Background />
      <Center gap={30}>
        <div style={{ scale: String(s) }}>
          <LogoIcon />
        </div>
        <GlowTitle text="talking john" size={88} delay={0.4} />
        <Sub text="64-bit revival" delay={0.8} />
      </Center>
    </AbsoluteFill>
  );
};

export const SceneTimeline: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const k = interpolate(frame, [1.2 * fps, 2.4 * fps], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });
  return (
    <AbsoluteFill>
      <Background />
      <Center gap={26}>
        <GlowTitle text="с 2011 и до сегодня" size={56} delay={0.2} />
        <div style={{ display: "flex", flexDirection: "column", gap: 14, alignItems: "center" }}>
          <Badge text="armv7 · ios 5+" color={COLORS.pink} delay={0.6} />
          <Badge text="arm64 · ios 15+" color={COLORS.teal} delay={0.9} />
        </div>
        <div style={{ width: 540, marginTop: 20 }}>
          <div style={{ height: 4, backgroundColor: "#3a1518", borderRadius: 2, position: "relative" }}>
            <div
              style={{
                position: "absolute",
                left: 0,
                top: 0,
                height: 4,
                width: `${k * 100}%`,
                backgroundColor: COLORS.dim,
                borderRadius: 2,
                boxShadow: `0 0 12px ${COLORS.glow}`,
              }}
            />
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", marginTop: 12 }}>
            {["5", "10", "15", "20", "сегодня"].map((l, i) => (
              <Sub key={l} text={l} delay={1.3 + i * 0.15} size={24} />
            ))}
          </div>
        </div>
        <Badge text="один геймплей: swift + uikit" color="#5a282e" dark delay={2.2} />
      </Center>
    </AbsoluteFill>
  );
};

export const SceneVoice: React.FC = () => {
  return (
    <AbsoluteFill>
      <Background />
      <Center gap={20}>
        <GlowTitle text="она слушает тебя" size={56} delay={0.2} />
        <Sub text="говоришь — повторяет, без кнопок" delay={0.6} />
        <Phone tilt={-4}>
          <GameScreen mode="voice" />
        </Phone>
        <div style={{ display: "flex", gap: 14 }}>
          <Badge text="+9 полутонов" color={COLORS.pink} delay={1.6} />
          <Badge text="soundtouch 2.3.3" color={COLORS.teal} delay={1.9} />
        </div>
      </Center>
    </AbsoluteFill>
  );
};

export const SceneGameplay: React.FC = () => {
  return (
    <AbsoluteFill>
      <Background />
      <Center gap={18}>
        <GlowTitle text="всё как в оригинале" size={56} delay={0.2} />
        <Phone tilt={4}>
          <GameScreen mode="play" />
        </Phone>
        <div style={{ display: "flex", flexDirection: "column", gap: 12, alignItems: "center" }}>
          <Badge text="пончик → делится" color={COLORS.pink} delay={1.2} />
          <Badge text="шприц → хор" color={COLORS.teal} delay={1.6} />
          <Badge text="таблетка пролетает" color={COLORS.amber} delay={2.0} />
        </div>
      </Center>
    </AbsoluteFill>
  );
};

export const SceneFinal: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames } = useVideoConfig();
  const fade = interpolate(
    frame,
    [durationInFrames - 1.0 * fps, durationInFrames],
    [0, 1],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  return (
    <AbsoluteFill>
      <Background />
      <Center gap={24}>
        <LogoIcon size={210} />
        <GlowTitle text="talking john" size={80} delay={0.5} />
        <Badge text="фан-порт · не связано с outfit7" color="#5a282e" dark delay={1.0} />
        <Sub text="github.com/dfilin787" delay={1.5} size={32} />
        <Sub text="/Talking-bacteria-John-64-bits" delay={1.8} size={26} />
      </Center>
      <AbsoluteFill style={{ backgroundColor: "#000", opacity: fade }} />
    </AbsoluteFill>
  );
};