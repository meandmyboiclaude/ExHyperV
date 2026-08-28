using ExHyperV.Services;
using ExHyperV.ViewModels;
using System.Windows.Controls;

namespace ExHyperV.Views.Pages
{
    public partial class VirtualMachinesPage : Page
    {
        public VirtualMachinesPage()
        {
            InitializeComponent();
            this.DataContext = new VirtualMachinesPageViewModel(new VmQueryService(), new VmPowerService());
        }
    }
}