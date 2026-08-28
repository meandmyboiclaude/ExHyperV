using ExHyperV.ViewModels;
using System.Windows.Controls;

namespace ExHyperV.Views.Pages
{
    public partial class SwitchPage : Page
    {
        public SwitchPage()
        {
            InitializeComponent();
            DataContext = new VMNetViewModel();
        }
    }
}