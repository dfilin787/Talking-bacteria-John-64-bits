import React from "react";
import { AbsoluteFill, Composition, Sequence, useVideoConfig } from "remotion";
import { Audio } from "@remotion/media";
import { staticFile } from "remotion";
import { TransitionSeries, linearTiming } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { BeatLayer } from "./atoms";
import {
  SceneFinal,
  SceneGameplay,
  SceneLogo,
  SceneTimeline,
  SceneVoice,
} from "./scenes";

const TRANS = 7;

const Sfx: React.FC<{ src: string; at: number; vol?: number }> = ({
  src,
  at,
  vol = 0.5,
}) => {
  const { fps } = useVideoConfig();
  return (
    <Sequence from={Math.round(at * fps)} name={src}>
      <Audio src={staticFile(`sfx/${src}`)} volume={vol} />
    </Sequence>
  );
};

export const Promo: React.FC = () => {
  const { fps } = useVideoConfig();
  return (
    <AbsoluteFill style={{ backgroundColor: "#000" }}>
      <Audio src={staticFile("music.mp3")} volume={0.8} />
      <Sfx src="laugh.wav" at={9.5} />
      <Sfx src="eat1.wav" at={15.0} vol={0.45} />
      <Sfx src="explode.wav" at={17.5} />
      <Sfx src="multiply.wav" at={21.0} vol={0.4} />
      <BeatLayer>
        <TransitionSeries>
          <TransitionSeries.Sequence durationInFrames={3 * fps} name="Лого">
            <SceneLogo />
          </TransitionSeries.Sequence>
          <TransitionSeries.Transition
            presentation={fade()}
            timing={linearTiming({ durationInFrames: TRANS })}
          />
          <TransitionSeries.Sequence durationInFrames={5 * fps} name="Таймлайн">
            <SceneTimeline />
          </TransitionSeries.Sequence>
          <TransitionSeries.Transition
            presentation={fade()}
            timing={linearTiming({ durationInFrames: TRANS })}
          />
          <TransitionSeries.Sequence durationInFrames={6 * fps} name="Голос">
            <SceneVoice />
          </TransitionSeries.Sequence>
          <TransitionSeries.Transition
            presentation={fade()}
            timing={linearTiming({ durationInFrames: TRANS })}
          />
          <TransitionSeries.Sequence durationInFrames={6 * fps} name="Геймплей">
            <SceneGameplay />
          </TransitionSeries.Sequence>
          <TransitionSeries.Transition
            presentation={fade()}
            timing={linearTiming({ durationInFrames: TRANS })}
          />
          <TransitionSeries.Sequence durationInFrames={7 * fps} name="Финал">
            <SceneFinal />
          </TransitionSeries.Sequence>
        </TransitionSeries>
      </BeatLayer>
    </AbsoluteFill>
  );
};

export const RemotionPromo: React.FC = () => {
  return (
    <Composition
      id="TalkingJohnPromo"
      component={Promo}
      durationInFrames={27 * 30}
      fps={30}
      width={720}
      height={1280}
    />
  );
};