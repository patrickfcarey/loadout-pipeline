# iso-pipeline Architecture

      +-------------------+
      |   Job File Input  |
      |  (example.jobs)   |
      +---------+---------+
                |
                v
      +-------------------+
      |      Queue        |
      | (file-based tmp)  |
      +---------+---------+
                |
   +------------+-------------+
   |                          |
   v                          v

+-------------+ +-------------+
| Unzip Worker| | Unzip Worker|
| (bash) | | (bash) |
+------+------+\ /+------+------+
| \ / |
v \ / v
+-------------------+-------------------+
| Dispatch Worker (per destination) |
+---------+---------+---------+---------+
| | |
v v v
FTP HDL SD


**Legend:**

- **Job File Input** – plain text file listing ISO paths and destinations.  
- **Queue** – bounded, temporary storage for jobs.  
- **Unzip Workers** – parallel workers, extract ISOs into `/tmp`.  
- **Dispatch Workers** – send unzipped content to configured adapters.  
- **Adapters** – FTP, HDL dump, SD card, or future destinations.  