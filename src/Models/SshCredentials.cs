namespace ExHyperV.Models
{
    public class SshCredentials
    {
        public string Host { get; set; } = string.Empty;

        public int Port { get; set; }
        public string Username { get; set; } = string.Empty;
        public string Password { get; set; } = string.Empty;

        public string ProxyHost { get; set; } 
        public int? ProxyPort { get; set; }   
        public bool UseProxy { get; set; }

        public bool InstallGraphics { get; set; } = true;


    }
}
