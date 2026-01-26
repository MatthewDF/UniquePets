
# Unique Pets by Mazu

This addon for Ashita allows you to set a model for your pet and for others', while keeping your change unique. That means you can replace your Wyvern, for example, but every other Wyvern will remain unchanged.

<img width="945" height="725" alt="image" src="https://github.com/user-attachments/assets/90bab1f6-3988-4737-ac7f-deaed05f243f" />
<img width="655" height="585" alt="image" src="https://github.com/user-attachments/assets/c43d9087-4af2-45f2-915b-02654277a149" />
<img width="520" height="478" alt="image" src="https://github.com/user-attachments/assets/ab7e739a-cd08-4dac-89d7-def76c3e2bc9" />
<img width="522" height="479" alt="image" src="https://github.com/user-attachments/assets/11aa6e33-015d-44f8-aa2c-480bcdcb94e0" />


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

## Tips and Tricks
* If you know what you want to make your pet look like, use the ModelSniffer while near that creature in-game to get its model number, then use that for your model swap.
* With the addon loaded, use /addon reload UniquePets to quickly refresh it once you make a change in your Settings.Lua - Otherwise it won't show!

## Current Known Issues
* Sometimes when your pet is first summoned/called, it will briefly revert to its base model. This is because the game doesn't yet know you're their owner, and it'll update as soon as they move.
* Sometimes when your pet is released/dies, it will revert to its base model. This is due to the game forgetting you're the owner of the pet at that moment, and so the model is reverted.
