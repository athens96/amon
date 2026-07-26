using AMon.ClaudeIntegration;

try
{
    var input = await Console.In.ReadToEndAsync();
    if (!string.IsNullOrWhiteSpace(input))
    {
        new ClaudeHookProcessor().Process(input);
    }
}
catch
{
    // Hooks are observational. They must never block Claude Code or emit output.
}

return 0;
