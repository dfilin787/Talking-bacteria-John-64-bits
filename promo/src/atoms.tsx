import React from "react";
import {
  AbsoluteFill,
  Img,
  interpolate,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
  Easing,
} from "remotion";
import { loadFont as loadUnbounded } from "@remotion/google-fonts/Unbounded";
import { loadFont as loadMontserrat } from "@remotion/google-fonts/Montserrat";
import { beatPulse } from "./beats";

const unbounded = loadUnbounded();
const montserrat = loadMontserrat();

export const FONT_HEAD = unbounded.fontFamily;
export const FONT_BODY = montserrat.fontFamily;

export const COLORS = {
  pink: "#eea8be",
  teal: "#96d6c8",
  amber: "#f0c88c",
  glow: "#ff785a",
  text: "#ffffff",
  dim: "#ffd2c2",
};

export const Background: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  return (
    <AbsoluteFill style={{ backgroundColor: "#1a0608" }}>
      <Img
        src={staticFile("ui/bg.jpg")}
        style={{
          width: "100%",
          height: "100%",
          objectFit: "cover",
          opacity: 0.3,
          filter: "saturate(1.1)",
        }}
      />
      {[0, 1, 2, 3].map((i) => {
        const x = 10 + 70 * ((i * 0.37 + 0.05 * Math.sin(t * 0.3 + i)) % 1);
        const y = 8 + 78 * ((i * 0.29 + 0.04 * Math.cos(t * 0.23 + i * 2)) % 1);
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              left: `${x}%`,
              top: `${y}%`,
              width: 340,
              height: 300,
              borderRadius: "50%",
              background:
                "radial-gradient(circle, rgba(150,25,32,0.5) 0%, rgba(150,25,32,0) 70%)",
              filter: "blur(30px)",
            }}
          />
        );
      })}
      <AbsoluteFill
        style={{
          background:
            "radial-gradient(ellipse at center, rgba(0,0,0,0) 45%, rgba(5,1,2,0.85) 100%)",
        }}
      />
    </AbsoluteFill>
  );
};

export const BeatLayer: React.FC<{ children: React.ReactNode }> = ({
  children,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  const p = beatPulse(t);
  const shake = Math.round(6 * p) * (frame % 2 === 0 ? 1 : -1);
  return (
    <AbsoluteFill
      style={{
        scale: String(1 + 0.035 * p),
        translate: `${shake}px 0px`,
      }}
    >
      {children}
      <AbsoluteFill
        style={{
          backgroundColor: COLORS.glow,
          opacity: 0.1 * p,
          mixBlendMode: "screen",
        }}
      />
    </AbsoluteFill>
  );
};

export const GlowTitle: React.FC<{
  text: string;
  size?: number;
  color?: string;
  delay?: number;
}> = ({ text, size = 64, color = COLORS.text, delay = 0 }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const a = interpolate(frame, [delay * fps, (delay + 0.5) * fps], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });
  return (
    <div
      style={{
        fontFamily: FONT_HEAD,
        fontWeight: 800,
        fontSize: size,
        color,
        textAlign: "center",
        opacity: a,
        translate: `0px ${(1 - a) * 26}px`,
        textShadow: `0 0 18px ${COLORS.glow}, 0 0 46px ${COLORS.glow}`,
        lineHeight: 1.15,
        padding: "0 40px",
      }}
    >
      {text}
    </div>
  );
};

export const Sub: React.FC<{ text: string; delay?: number; size?: number }> = ({
  text,
  delay = 0,
  size = 30,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const a = interpolate(frame, [delay * fps, (delay + 0.5) * fps], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return (
    <div
      style={{
        fontFamily: FONT_BODY,
        fontWeight: 600,
        fontSize: size,
        color: COLORS.dim,
        textAlign: "center",
        opacity: a,
        textShadow: `0 0 12px ${COLORS.glow}`,
        padding: "0 50px",
      }}
    >
      {text}
    </div>
  );
};

export const Badge: React.FC<{
  text: string;
  color: string;
  delay?: number;
  dark?: boolean;
}> = ({ text, color, delay = 0, dark = false }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = interpolate(frame, [delay * fps, (delay + 0.45) * fps], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.spring({ damping: 14, stiffness: 160 }),
  });
  return (
    <div
      style={{
        fontFamily: FONT_BODY,
        fontWeight: 700,
        fontSize: 26,
        color: dark ? "#ffdcd2" : "#2a141a",
        backgroundColor: color,
        borderRadius: 999,
        padding: "12px 30px",
        scale: String(s),
        boxShadow: `0 0 24px ${color}66`,
        whiteSpace: "nowrap",
      }}
    >
      {text}
    </div>
  );
};

const pad = (n: number) => String(n).padStart(4, "0");

export const Bacteria: React.FC<{
  clip: "sway" | "talk" | "listen";
  count: number;
  width: number;
  fps?: number;
}> = ({ clip, count, width, fps = 8 }) => {
  const frame = useCurrentFrame();
  const { fps: vfps } = useVideoConfig();
  const idx =
    clip === "listen" ? 0 : Math.floor((frame / vfps) * fps) % count;
  return (
    <Img
      src={staticFile(`anim/${clip}/${pad(idx)}.png`)}
      style={{ width, height: "auto" }}
    />
  );
};

export const Phone: React.FC<{
  children: React.ReactNode;
  tilt?: number;
}> = ({ children, tilt = 0 }) => {
  return (
    <div
      style={{
        width: 332,
        height: 610,
        backgroundColor: "#101012",
        borderRadius: 42,
        padding: 16,
        rotate: `${tilt}deg`,
        boxShadow: "0 24px 70px rgba(0,0,0,0.6)",
        position: "relative",
      }}
    >
      <div
        style={{
          width: "100%",
          height: "100%",
          borderRadius: 12,
          overflow: "hidden",
          position: "relative",
          backgroundColor: "#000",
        }}
      >
        {children}
      </div>
      <div
        style={{
          position: "absolute",
          top: 7,
          left: "50%",
          translate: "-50% 0",
          width: 68,
          height: 6,
          borderRadius: 3,
          backgroundColor: "#28282c",
        }}
      />
    </div>
  );
};

export const GameScreen: React.FC<{ mode: "voice" | "play" }> = ({ mode }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  return (
    <AbsoluteFill>
      <Img
        src={staticFile("ui/bg.jpg")}
        style={{ width: "100%", height: "100%", objectFit: "cover" }}
      />
      {mode === "voice" ? (
        <div style={{ position: "absolute", left: 80, top: 150 }}>
          {(t * 0.5) % 1 < 0.45 ? (
            <Bacteria clip="listen" count={1} width={130} />
          ) : (
            <Bacteria clip="talk" count={16} width={130} fps={14} />
          )}
        </div>
      ) : (
        <>
          <div style={{ position: "absolute", left: 26, top: 60 }}>
            <Bacteria clip="sway" count={21} width={110} />
          </div>
          <div style={{ position: "absolute", left: 130, top: 260 }}>
            <Bacteria clip="sway" count={21} width={130} />
          </div>
          <Img
            src={staticFile("ui/pill-50.png")}
            style={{
              position: "absolute",
              width: 44,
              left: 60 + (Math.sin(t * 1.7) * 0.5 + 0.5) * 170,
              top: 200 + (Math.cos(t * 1.3) * 0.5 + 0.5) * 150,
            }}
          />
        </>
      )}
      {["injection-60.png", "gumb-pill-60.png", "gumb-donut-60.png"].map(
        (b, i) => (
          <Img
            key={b}
            src={staticFile(`ui/${b}`)}
            style={{
              position: "absolute",
              width: 52,
              right: 10,
              top: 120 + i * 66,
            }}
          />
        ),
      )}
    </AbsoluteFill>
  );
};

export const LogoIcon: React.FC<{ size?: number }> = ({ size = 250 }) => {
  return (
    <div
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.23,
        background: "linear-gradient(180deg,#d63c2c 0%,#781012 100%)",
        position: "relative",
        overflow: "hidden",
        boxShadow: `0 0 60px ${COLORS.glow}88`,
      }}
    >
      <div style={{ position: "absolute", left: size * 0.15, top: -size * 0.02 }}>
        <Bacteria clip="sway" count={21} width={size * 0.7} />
      </div>
    </div>
  );
};