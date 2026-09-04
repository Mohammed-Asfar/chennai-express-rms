/**
 * The printed menu, transcribed.
 *
 * Prices in whole rupees; converted to paise at a single boundary in the seed
 * script, never scattered through this data.
 *
 * A bare number is one portion. An array is a dish sold in sizes or
 * preparations — `[['Full', 440], ['Half', 240]]` — which the till shows as a
 * picker rather than as separate dishes.
 *
 * Card: #183, ECR Road, Pudupattinam, Kalpakkam — 603102.
 */

export const MENU = [
  {
    category: 'Soup - Veg',
    items: [
      ['Veg Clear Soup', 55],
      ['Sweet Corn Veg Soup', 70],
      ['Hot & Sour Veg Soup', 70],
      ['Veg Manchow Soup', 60],
      ['Veg Noodles Soup', 60],
      ['Mushroom Soup', 70],
      ['Cream of Mushroom Soup', 70],
      ['Cream of Veg Soup', 70],
    ],
  },
  {
    category: 'Soup - Non Veg',
    items: [
      ['Chicken Clear Soup', 75],
      ['Sweet Corn Chicken Soup', 80],
      ['Chicken Manchow Soup', 80],
      ['Chicken Noodles Soup', 80],
      ['Hot & Sour Chicken Soup', 100],
      ['Mutton Soup', 90],
      ['Cream of Chicken Soup', 120],
      ['Cream of Mutton Soup', 135],
    ],
  },
  {
    category: 'Non Veg Starters',
    items: [
      ['Prawn Szechwan Chilly', 240],
      ['Prawn Manchurian', 240],
      ['Prawn Pepper Fry', 240],
      ['Prawn 65', 240],
      ['Fish Chilly', 240],
      ['Fish Manchurian', 220],
      ['Fish Fry', 260],
      ['Fish Finger', 240],
      ['Crab Lollypop', 240],
      ['Kadamba Chilly', 240],
      ['Mutton Chilly', 250],
      ['Chicken Lollypop', 200],
      ['Lollypop Manchurian', 220],
      ['Lemon Chicken', 200],
      ['Ginger Chicken', 200],
      ['Garlic Chicken', 200],
      // The card prices this pair on one line: "150.00 / 160.00".
      ['Chilly Chicken', [['Dry', 150], ['Gravy', 160]]],
      ['Chicken Manchurian', 160],
      // Two preparations at one price, so the kitchen ticket has to say which.
      ['Pepper Chicken', [['Dry', 200], ['Fry', 200]]],
      ['Chicken 65', 160],
      ['Egg Chilly', 130],
      ['Egg Manchurian', 130],
      ['Egg Bhurjee', 60],
    ],
  },
  {
    category: 'Veg Starters',
    items: [
      ['Paneer 65', 160],
      ['Paneer Chilly', 170],
      ['Paneer Manchurian', 170],
      ['Mushroom Chilly', 170],
      ['Mushroom Manchurian', 170],
      ['Gobi Chilly', [['Dry', 140], ['Gravy', 140]]],
      ['Gobi Manchurian', 140],
      ['Gobi 65', 140],
    ],
  },
  {
    category: 'Tandoori - Roti / Naan',
    items: [
      ['Tandoori Roti', 25],
      ['Butter Roti', 30],
      ['Naan', 25],
      ['Kulcha', 50],
      ['Tandoori Paratha', 40],
      ['Butter Naan', 30],
      ['Garlic Naan', 50],
      ['Kashmiri Naan', 70],
      ['Masala Kulcha', 60],
      ['Stuff Paratha', 60],
      ['Aloo Paratha', 60],
      ['Lachchha Paratha', 60],
      ['Paneer Paratha', 70],
      ['Paneer Kulcha', 70],
      ['Cheese Naan', 90],
      ['Cheese Paratha', 90],
    ],
  },
  {
    category: 'Tandoori - Veg',
    items: [
      ['Aloo Tikka', 180],
      ['Gobi Tikka', 180],
      ['Paneer Tikka', 200],
      ['Paneer Malai Tikka', 220],
      ['Mushroom Tikka', 190],
    ],
  },
  {
    category: "Tandoori - Kabab's",
    items: [
      // One dish at three prices. As three items staff had to find the right
      // "(Half)" among them; as portions they tap the dish and pick the size.
      ['Tandoori Chicken', [['Full', 440], ['Half', 240], ['Single', 120]]],
      ['Chicken Tikka', 190],
      ['Chicken Malai Tikka', 250],
      ['Chicken Haryali Kabab', 240],
      ['Lasuni Kabab', 250],
      ['Tandoori Fish', 250],
    ],
  },
  {
    category: 'Fried Rice & Noodles - Non Veg',
    items: [
      // The card prices rice and noodles together — "Mutton Fried Rice /
      // Noodles  190.00" — but they are two dishes. Sold as one line nobody can
      // tell which the customer asked for, and the kitchen ticket does not say.
      // Split, at the shared price the card gives.
      ['Mutton Fried Rice', 190],
      ['Mutton Fried Noodles', 190],
      ['Mutton Szechwan Fried Rice', 200],
      ['Mutton Szechwan Fried Noodles', 200],
      ['Chicken Fried Rice', 140],
      ['Chicken Fried Noodles', 140],
      ['Chicken Szechwan Fried Rice', 150],
      ['Chicken Szechwan Fried Noodles', 150],
      ['Egg Fried Rice', 120],
      ['Egg Fried Noodles', 120],
      ['Egg Szechwan Fried Rice', 130],
      ['Egg Szechwan Fried Noodles', 130],
      ['Mixed Fried Rice', 220],
      ['Mixed Fried Noodles', 220],
      ['Mixed Szechwan Fried Rice', 230],
      ['Mixed Szechwan Fried Noodles', 230],
      ['Prawn Fried Rice', 190],
      ['Prawn Fried Noodles', 190],
      ['Prawn Szechwan Fried Rice', 200],
      ['Prawn Szechwan Fried Noodles', 200],
    ],
  },
  {
    category: 'Fried Rice & Noodles - Veg',
    items: [
      ['Veg Fried Rice', 120],
      ['Veg Fried Noodles', 120],
      ['Veg Szechwan Fried Rice', 130],
      ['Veg Szechwan Fried Noodles', 130],
      ['Paneer Fried Rice', 160],
      ['Paneer Fried Noodles', 160],
      ['Paneer Szechwan Fried Rice', 170],
      ['Paneer Szechwan Fried Noodles', 170],
      ['Mushroom Fried Rice', 150],
      ['Mushroom Fried Noodles', 150],
      // The card reads "Mushroom Szechwan Rice / Noodles" without "Fried", but
      // it sits among the fried rice and is priced with them.
      ['Mushroom Szechwan Fried Rice', 160],
      ['Mushroom Szechwan Fried Noodles', 160],
      ['Gobi Fried Rice', 140],
      ['Gobi Fried Noodles', 140],
      ['Gobi Szechwan Fried Rice', 140],
      ['Gobi Szechwan Fried Noodles', 140],
      ['Mixed Veg Fried Rice', 160],
      ['Mixed Veg Fried Noodles', 160],
    ],
  },
  {
    category: 'Rice',
    items: [
      ['Steam Rice', 60],
      ['Jeera Rice', 120],
      ['Ghee Rice', 130],
      ['Peas Pulav', 150],
      ['Butter Rice', 150],
      ['Mushroom Pulav', 160],
      ['Paneer Pulav', 160],
      ['Veg Pulav', 150],
    ],
  },
  {
    category: 'Dum Biriyani',
    items: [
      ['Chicken Biriyani', 140],
      ['Mutton Biriyani', 220],
      ['Prawn Biriyani', 200],
      ['Egg Biriyani', 100],
      ['Veg Biriyani', 130],
      ['Special Biriyani', 180],
    ],
  },
  {
    category: 'Indian Masala - Non Veg',
    items: [
      ['Chicken Jhalfareji', 190],
      ['Chicken Dopiyaza', 190],
      ['Chetinadu Chicken', 190],
      ['Pepper Chicken Masala', 190],
      ['Chicken Kolhapuri', 190],
      ['Kadai Chicken Masala', 190],
      ['Hydrabadi Chicken', 190],
      ['Chicken Masala', 180],
      ['Banjara Chicken', 200],
      ['Butter Chicken Masala', 180],
      ['Chicken Tikka Masala', 190],
      ['Mutton Masala', 220],
      ['Motten Pepper Fry', 230],
      ['Egg Masala', 130],
      ['Fish Curry', 230],
      ['Prawn Curry', 220],
    ],
  },
  {
    category: 'Indian Masala - Veg',
    items: [
      ['Veg Jhalfareji', 140],
      ['Kadai Paneer', 150],
      ['Paneer Butter Masala', 160],
      ['Paneer Do Piyaja', 160],
      ['Mutter Paneer Masala', 160],
      ['Aloo Jeera', 140],
      ['Aloo Gobi', 140],
      ['Aloo Mutter', 140],
      ['Gobi Masala', 140],
      ['Gobi Mutter', 140],
      ['Mixed Veg Curry', 140],
      ['Veg Kadai', 140],
      ['Green Peas Masala', 140],
      ['Chana Masala', 140],
      ['Daal Fry', 120],
      ['Daal Tadka', 130],
      ['Double Daal Tadka', 140],
      ['Bhindi Masala', 165],
      ['Mushroom Masala', 150],
      ['Green Salad', 80],
    ],
  },
  {
    category: 'Shawarma & Roll Items',
    items: [
      ['Regular Shawarma Roll', 100],
      ['Special Shawarma Roll', 120],
      ['Regular Shawarma Plate', 140],
      ['Special Shawarma Plate', 150],
      ['Mexican Shawarma', 150],
      ['Chicken Roll', 100],
      ['Mutton Roll', 150],
      ['Egg Roll', 90],
      ['Veg Roll', 90],
      ['Paneer Roll', 140],
      ['Mushroom Roll', 140],
      ['Chicken Tikka Roll', 150],
    ],
  },
  {
    category: 'Lassi & Fresh Juice',
    items: [
      ['Sweet Lassi', 65],
      ['Mango Lassi', 85],
      ['Strawberry Lassi', 95],
      ['Salt Lassi', 65],
      ['Plain Lassi', 55],
      // "Soft Drinks ........" is priced with dots on the card. Left out
      // deliberately rather than invented — an item that bills the wrong amount
      // is worse than one a cashier has to add.
    ],
  },
  {
    category: 'Bucket Biriyani',
    items: [
      ['Chicken Bucket Biriyani', 999],
      ['Mutton Bucket Biriyani', 1699],
    ],
  },
]
