using FreeFlow.Services;
using Xunit;

public class SpeechHeuristicsTests
{
    [Fact]
    public void SilenceYieldsNoSpeech()
    {
        var samples = Enumerable.Repeat(0.001, 100).ToArray();
        var a = SpeechHeuristics.Analyze(samples, 2.0);
        Assert.True(a.SpeechSeconds < 0.05, $"flat room noise yields ~0 speech seconds, got {a.SpeechSeconds}");
    }

    [Fact]
    public void SustainedSpeechAboveFloorIsCounted()
    {
        var samples = Enumerable.Repeat(0.001, 60).Concat(Enumerable.Repeat(0.25, 40)).ToArray();
        var a = SpeechHeuristics.Analyze(samples, 2.0);
        Assert.Equal(0.8, a.SpeechSeconds, precision: 2);
        Assert.True(a.NoiseFloorRms < 0.01, "noise floor tracks the quiet part");
    }

    [Fact]
    public void BriefCoughIsNotSpeech()
    {
        var samples = Enumerable.Repeat(0.002, 99).ToArray();
        samples[50] = 0.5;
        var a = SpeechHeuristics.Analyze(samples, 3.0);
        Assert.True(a.SpeechSeconds < 0.3, $"a single loud transient is not sustained speech, got {a.SpeechSeconds}");
    }

    [Fact]
    public void DeadCalmRoomHissIsNotSpeech()
    {
        var samples = Enumerable.Repeat(0.0005, 100).ToArray();
        var a = SpeechHeuristics.Analyze(samples, 2.0);
        Assert.True(a.SpeechSeconds < 0.05, "the absolute floor keeps dead-calm hiss from counting as speech");
    }

    [Fact]
    public void EmptyInputsAreSafe()
    {
        Assert.Equal(0, SpeechHeuristics.Analyze(Array.Empty<double>(), 2.0).SpeechSeconds);
        Assert.Equal(0, SpeechHeuristics.Analyze(new[] { 0.5, 0.1 }, 0).SpeechSeconds);
    }
}
