using ExHyperV.ViewModels;
using System.Windows.Controls;

namespace ExHyperV.Views.Pages
{
    public partial class HostPage : Page
    {
        public HostPage()
        {
            InitializeComponent();
            this.DataContext = new HostPageViewModel();
        }
    }
}