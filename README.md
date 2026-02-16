# Unique Pets by Mazu
<p align="center">
<img width="532" height="473" alt="Screenshot 2026-02-16 150136" src="https://github.com/user-attachments/assets/444877a0-d581-4627-8a7d-7a4bda5c0665" />
</p>

This addon for Ashita allows you to set a model for your pet and for others', while keeping your change unique. That means you can replace your Wyvern, for example, but every other Wyvern will remain unchanged.
<p align="center">
<img width="573" height="410" alt="Screenshot 2026-02-04 204001" src="https://github.com/user-attachments/assets/b0306640-1b1f-403e-b7ee-929450d81644" />
</p>

<img width="588" height="474" alt="image" src="https://github.com/user-attachments/assets/4e92cab4-575d-429c-8450-3a14a152db08" />

<img width="562" height="425" alt="image" src="https://github.com/user-attachments/assets/ca5bed25-eb44-4e0b-b5a2-8e44fe22d823" /> <img width="463" height="300" alt="Screenshot 2026-02-16 150941" src="https://github.com/user-attachments/assets/f075534d-c1b4-42cb-8505-b09ac4465999" />

<img width="673" height="782" alt="image" src="https://github.com/user-attachments/assets/92e3b33f-f6d9-4367-9e2b-964919a812e3" />

/<img width="761" height="121" alt="image" src="https://github.com/user-attachments/assets/64666985-41a2-4624-ab84-0d15114e1b60" />

## Installation

Place the UniquePets folder in your HorizonXI\Game\addons folder, then add the addon to your default.txt in HorizonXI\Game\scripts.

## How to Use

* Load the addon and in-game type /uniquepets or /upets to bring up the window.
* Add a pet name and a model number of your choice (there's a .txt file with some I've found, and more info below.)
* Pet and Player names are case-sensitive!

## Finding Model Numbers

I've included some model numbers I've tested in the ModelNumbersTested.txt folder that you can use, but you can also use the ModelSniffer.Lua addon to locate more. Warning: It's very verbose.

## ***About Animations and Models***
You should know that there's no harm in replacing models for your characters or pets, but it *can* look funny if the pet and the model aren't well suited to each other. This is **most evident** on Avatars and their Bloodpacts. Keep that in mind for best results <3
I've added an 'Animation Patching' tab to help fix this. It's not perfect, but you can choose for certain animations to play instead of ALL broken animations. Experiment to find what works best for you!

## Tips and Tricks
* If you know what you want to make your pet look like, use the ModelSniffer while near that creature in-game to get its model number, then use that for your model swap.
* With the addon loaded, use /addon reload UniquePets to quickly refresh it once you make a change in your Settings.Lua - Otherwise it won't show!

## Current Known Issues
* Sometimes when your pet is first summoned/called, it will briefly revert to its base model. This is because the game doesn't yet know you're their owner, and it'll update as soon as they move.
* Sometimes when your pet is released/dies, it will revert to its base model. This is due to the game forgetting you're the owner of the pet at that moment, and so the model is reverted.
