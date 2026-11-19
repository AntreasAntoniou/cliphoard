using Microsoft.UI.Xaml;
namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    private readonly AgentWriteController agents;
    private readonly DispatcherTimer agentPoll = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private void InitializeAgents()
    {
        agents.Changed += () => { if (!locked && !closing) { BuildChrome(); Refresh(); } };
        agents.ApprovalRequested += () => { if (!locked && !closing && store.State.AgentNotifications) tray?.NotifyAgentRequest(); };
        agentPoll.Tick += async (_, _) =>
        {
            if (locked || closing) return;
            try { await agents.PollAsync(); }
            catch { agents.Disconnect(); if (!locked && !closing) Notice("The agent connection could not continue."); }
        };
        agentPoll.Start();
    }
    private void ShowAgentSettings() { ShowPanel(); ShowSettings(false, "Agent notes"); }
}
